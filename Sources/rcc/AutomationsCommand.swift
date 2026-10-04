import ArgumentParser
import Foundation
import RCCAutomation
import RCCBootstrap
import RCCCalendar
import RCCCore
import RCCDiagnostics
import RCCPlatform

/// `rcc automations …` — Tier 0 automation (SPEC §11). `run` is what launchd invokes;
/// everything else is for a person at a terminal. `approve` in particular exists **only**
/// here: it is not, and will never be, an MCP tool (SPEC §8.3, §6.4).
struct Automations: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "automations",
        abstract: "Manage unattended automation rules and approve what they stage.",
        subcommands: [
            Run.self, List.self, Show.self, Add.self, Enable.self, Disable.self, Remove.self,
            Pending.self, Approve.self, Reject.self, Log.self,
        ]
    )

    // MARK: - run

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Execute due rules. Invoked by launchd on a schedule."
        )

        @Flag(name: .long, help: "Show what each rule would do, changing nothing.")
        var dryRun = false

        @Option(name: .long, help: "Run only this rule, even if it is not yet due.")
        var rule: String?

        func run() async throws {
            do {
                try DisclaimGate.require(Disclaim.result)
                let store = try Store()
                let runner = AutomationRunner(
                    repository: EventKitRepository(), store: store, notifier: OSANotifier()
                )
                let reports = try await runner.runDue(ruleID: rule, dryRun: dryRun)
                // launchd discards stdout, so print only for a person.
                guard isatty(STDOUT_FILENO) == 1 || rule != nil || dryRun else { return }
                if reports.isEmpty {
                    Output.line(try store.rules().isEmpty ? "No automation rules are configured." : "No rules are due.")
                }
                for report in reports {
                    Output.line("\(report.ruleName) [\(report.ruleID)]: \(report.outcome)"
                        + (report.matched.map { ", \($0) matched" } ?? ""))
                    if let detail = report.detail { Output.line(indent(detail)) }
                }
            } catch {
                exitWith(error)
            }
        }
    }

    // MARK: - rules

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List automation rules.")
        func run() async throws {
            do {
                let store = try Store()
                let rules = try store.rules()
                if rules.isEmpty { Output.line("No automation rules. Add one with `rcc automations add <file.json>`.") }
                for rule in rules {
                    Output.line("\(rule.id)  \(rule.enabled ? "on " : "off")  \(rule.name)")
                    Output.line("    next: \(rule.nextDueAt ?? "—")   last: \(rule.lastOutcome ?? "never run")"
                        + (rule.lastRunAt.map { " at \($0)" } ?? ""))
                }
            } catch {
                exitWith(error)
            }
        }
    }

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one rule, its definition, and its recent runs.")
        @Argument var id: String
        func run() async throws {
            do {
                let store = try Store()
                guard let record = try store.rule(id: id) else { throw RCCError(.validation, "No automation rule \(id).") }
                let description = try RuleCatalog(repository: EventKitRepository(), store: store).describe(record, runs: 10)
                Output.line(prettyJSON(description))
            } catch {
                exitWith(error)
            }
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a rule from a JSON file (or - for stdin). See SPEC §11 for the format."
        )
        @Argument(help: "Path to the rule's JSON document, or - to read stdin.")
        var file: String
        func run() async throws {
            do {
                try DisclaimGate.require(Disclaim.result)
                let data = file == "-"
                    ? FileHandle.standardInput.readDataToEndOfFile()
                    : try Data(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath))
                guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw RCCError(.validation, "The rule file is not a JSON object.")
                }
                let store = try Store()
                let record = try await RuleCatalog(repository: EventKitRepository(), store: store).create(document)
                Output.line("Added \(record.id): \(record.name) — next run \(record.nextDueAt ?? "unscheduled").")
                Output.line("Preview it with: rcc automations run --dry-run --rule \(record.id)")
            } catch let error as RuleError {
                exitWith(RCCError(.validation, error.message))
            } catch {
                exitWith(error)
            }
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a rule on.")
        @Argument var id: String
        func run() async throws { await toggle(id, true) }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a rule off without deleting it.")
        @Argument var id: String
        func run() async throws { await toggle(id, false) }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a rule. Its run history is kept.")
        @Argument var id: String
        func run() async throws {
            do {
                try RuleCatalog(repository: EventKitRepository(), store: try Store()).delete(id: id)
                Output.line("Removed \(id).")
            } catch {
                exitWith(error)
            }
        }
    }

    // MARK: - staged actions

    struct Pending: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List staged actions awaiting approval.")
        func run() async throws {
            do {
                let store = try Store()
                try store.expireStagedActions(now: Date())
                let pending = try store.stagedActions(states: ["pending"])
                if pending.isEmpty { Output.line("Nothing is waiting for approval.") }
                let executor = StagedActionExecutor(repository: EventKitRepository(), store: store)
                for action in pending {
                    printAction(action, items: executor.items(of: action))
                    Output.line("")
                }
            } catch {
                exitWith(error)
            }
        }
    }

    /// The approval step. A human at a terminal, every time: stdin must be a TTY and the
    /// action's id must be typed back. A model driving a shell (Claude Code's Bash tool,
    /// say) has no TTY, so it cannot approve anything — SPEC §8.3's whole point. Same-user
    /// processes that fake a TTY are out of scope, as for every local tool (§6.4).
    struct Approve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Review and execute a staged action. Must be run by a person in a terminal."
        )
        @Argument var id: String
        func run() async throws {
            do {
                guard isatty(STDIN_FILENO) == 1 else {
                    throw RCCError(
                        .usage, "Approval needs a person at an interactive terminal; stdin is not a TTY.",
                        remediation: "Run `rcc automations approve \(id)` yourself in Terminal."
                    )
                }
                try DisclaimGate.require(Disclaim.result)
                let store = try Store()
                try store.expireStagedActions(now: Date())
                let executor = StagedActionExecutor(repository: EventKitRepository(), store: store)
                guard let action = try store.stagedAction(id: id) else {
                    throw RCCError(.validation, "No staged action \(id). See `rcc automations pending`.")
                }
                guard action.state == "pending" || action.state == "executing" else {
                    throw RCCError(.validation, "Staged action \(id) is \(action.state); an approval is one-use.")
                }
                printAction(action, items: executor.items(of: action))
                Output.line("")
                Output.error("To execute this, type the action id (\(id)): ")
                guard readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces) == id else {
                    Output.line("Not approved. Nothing was changed.")
                    return
                }
                let result = try await executor.approve(id)
                for item in result.items { Output.line("  \(item.outcome.padding(toLength: 22, withPad: " ", startingAt: 0)) \(item.title)") }
                Output.line("")
                Output.line("\(id): \(result.state)")
            } catch let error as StagedActionExecutor.ApprovalError {
                exitWith(RCCError(.validation, error.description))
            } catch {
                exitWith(error)
            }
        }
    }

    struct Reject: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Discard a staged action without executing it.")
        @Argument var id: String
        func run() async throws {
            do {
                try StagedActionExecutor(repository: EventKitRepository(), store: try Store()).reject(id)
                Output.line("Rejected \(id). Nothing was changed.")
            } catch let error as StagedActionExecutor.ApprovalError {
                exitWith(RCCError(.validation, error.description))
            } catch {
                exitWith(error)
            }
        }
    }

    // MARK: - history

    struct Log: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show recent automation runs and audited writes.")
        @Option(name: .long, help: "Only this rule's runs.") var rule: String?
        @Option(name: .long, help: "How many entries of each kind.") var limit: Int = 20
        func run() async throws {
            do {
                let store = try Store()
                Output.line("Runs:")
                for run in try store.runs(ruleID: rule, limit: limit) {
                    Output.line("  \(run.startedAt)  \(run.ruleID)  \(run.outcome)" + (run.matched.map { " (\($0))" } ?? ""))
                    if let detail = run.detail { Output.line(indent(detail, by: 6)) }
                }
                Output.line("")
                Output.line("Audited writes:")
                for entry in try store.auditEntries(limit: limit) {
                    Output.line("  \(entry.at)  \(entry.context)  \(entry.kind)  \(entry.outcome)"
                        + (entry.approvalID.map { "  approval \($0)" } ?? ""))
                }
            } catch {
                exitWith(error)
            }
        }
    }
}

// MARK: - Helpers

private func toggle(_ id: String, _ enabled: Bool) async {
    do {
        let record = try await RuleCatalog(repository: EventKitRepository(), store: try Store())
            .update(id: id, document: nil, enabled: enabled)
        Output.line("\(record.id) is \(enabled ? "on" : "off").")
    } catch let error as RuleError {
        exitWith(RCCError(.validation, error.message))
    } catch {
        exitWith(error)
    }
}

private func printAction(_ action: Store.StagedActionRecord, items: [MatchedItem]) {
    Output.line("\(action.id)  \(action.summary)")
    Output.line("    staged \(action.createdAt), expires \(action.expiresAt), state \(action.state)")
    for item in items { Output.line("    • \(item.title) — \(item.detail)") }
}

private func indent(_ text: String, by spaces: Int = 4) -> String {
    let pad = String(repeating: " ", count: spaces)
    return text.split(separator: "\n", omittingEmptySubsequences: false).map { pad + $0 }.joined(separator: "\n")
}

private func prettyJSON(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// Notifications for automation runs, through the platform's osascript path.
struct OSANotifier: AutomationNotifier {
    func notify(title: String, body: String) {
        _ = Notifications.post(title: title, body: body)
    }
}
