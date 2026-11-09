import SwiftData
import SwiftUI

/// "You may be able to claim": on a journey that ended late enough (or was
/// cancelled) for the operator's Delay Repay scheme. The details a claim form
/// asks for, ready to copy; the operator's claim form; what the ticket cost,
/// for an estimate; and "Mark as claimed", which folds it to one line.
struct ClaimCard: View {
    let journey: Journey
    @Environment(\.modelContext) private var context
    @State private var price: String
    @State private var ticketType: TicketType
    @State private var copied = false
    @State private var saving = false
    @State private var error: String?

    init(journey: Journey) {
        self.journey = journey
        _price = State(initialValue: journey.claim?.ticketPricePence.map(Pence.text) ?? "")
        _ticketType = State(initialValue: journey.claim?.ticketType.flatMap { $0 == .unknown ? nil : $0 } ?? .single)
    }

    var body: some View {
        if let claim = journey.claim {
            Group {
                if claim.claimed {
                    claimedRow(claim)
                } else {
                    card(claim)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("claimCard")
        }
    }

    // MARK: Not yet claimed

    private func card(_ claim: DelayRepayClaim) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "sterlingsign.circle.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You may be able to claim")
                        .font(.headline)
                    Text(claim.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(claim.details(for: journey))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 12, style: .continuous))

            HStack(spacing: 10) {
                Button(copied ? "Copied" : "Copy details", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = claim.details(for: journey)
                    copied = true
                }
                .accessibilityIdentifier("copyClaimDetails")
                Link(destination: claim.claimUrl) {
                    Label("Open claim form", systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier("openClaimForm")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Divider()

            ticket(claim)

            Toggle("Mark as claimed", isOn: Binding(get: { claim.claimed }, set: { setClaimed($0) }))
                .disabled(saving)
                .accessibilityIdentifier("claimedToggle")

            if let error {
                Label(error, systemImage: "wifi.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .panel()
        .task(id: "\(price)|\(ticketType.rawValue)") { await saveTicketIfChanged() }
    }

    private func ticket(_ claim: DelayRepayClaim) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ticket price")
                Spacer()
                TextField("£0.00", text: $price)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 110)
                    .accessibilityIdentifier("ticketPrice")
            }
            Picker("Ticket", selection: $ticketType) {
                Text("Single").tag(TicketType.single)
                Text("Return").tag(TicketType.return)
            }
            .pickerStyle(.segmented)
            Group {
                if claim.band == nil {
                    Text("What you get back depends on how late the train you took instead was, or it's a refund if you didn't travel.")
                } else if let estimate = claim.estimatePence(price: Pence.parse(price), type: ticketType) {
                    Text("Estimated payout: \(Pence.format(estimate))")
                        .foregroundStyle(.primary)
                } else {
                    Text("Add the ticket price for an estimate. Prices stay with your journey.")
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Claimed

    private func claimedRow(_ claim: DelayRepayClaim) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label("Claimed", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.tint)
                .font(.subheadline.weight(.semibold))
            Text("Delay Repay")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") { setClaimed(false) }
                .font(.subheadline)
                .disabled(saving)
                .accessibilityIdentifier("unclaim")
        }
        .panel()
    }

    // MARK: Saving

    private func setClaimed(_ claimed: Bool) {
        Task {
            saving = true
            defer { saving = false }
            await save(ClaimUpdate(claimed: claimed))
        }
    }

    /// Typing a price sends once it pauses; an unreadable price waits for a readable one.
    private func saveTicketIfChanged() async {
        guard let claim = journey.claim else { return }
        let trimmed = price.trimmingCharacters(in: .whitespaces)
        let pence = trimmed.isEmpty ? nil : Pence.parse(trimmed)
        if !trimmed.isEmpty && pence == nil { return }
        // The type alone (no price yet) isn't worth sending.
        guard pence != claim.ticketPricePence || (pence != nil && ticketType != claim.ticketType) else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        await save(ClaimUpdate(ticketPricePence: pence.map { .value($0) } ?? .null, ticketType: .value(ticketType)))
    }

    private func save(_ update: ClaimUpdate) async {
        do {
            try await JourneySync.shared.setClaim(update, for: journey, in: context)
            error = nil
        } catch {
            if Task.isCancelled { return }
            self.error = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
