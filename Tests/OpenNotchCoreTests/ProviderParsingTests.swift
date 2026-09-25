import Foundation
import Testing
@testable import OpenNotchCore

// Fixtures mirror real responses captured during development, with identifiers removed.

@Suite("Claude")
struct ClaudeParsingTests {
    let response = """
    {
      "five_hour": {"utilization": 0.0, "resets_at": "2026-09-26T00:09:59.570238+00:00"},
      "seven_day": {"utilization": 69.0, "resets_at": "2026-09-26T01:59:59.570260+00:00"},
      "limits": [
        {"kind": "session", "group": "session", "percent": 0, "resets_at": "2026-09-26T00:09:59.570238+00:00", "scope": null},
        {"kind": "weekly_all", "group": "weekly", "percent": 69, "resets_at": "2026-09-26T01:59:59.570260+00:00", "scope": null},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 61, "resets_at": "2026-09-26T01:59:59.570419+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
      ]
    }
    """

    @Test func readsSessionWeeklyAndModelLimits() throws {
        let metrics = ClaudeProvider.parseUsage(try JSON(string: response))
        #expect(metrics.map(\.title) == ["5-hour", "Weekly", "Weekly · Fable"])
        #expect(metrics.map(\.usedPercent) == [0, 69, 61])
        #expect(metrics[0].window == .fiveHour)
        #expect(metrics[2].resetsAt == ISODate.parse("2026-09-26T01:59:59.570Z"))
    }

    @Test func fallsBackToLegacyKeys() throws {
        let legacy = #"{"five_hour": {"utilization": 12.5, "resets_at": "2026-09-26T00:00:00Z"}, "seven_day": {"utilization": 40}}"#
        let metrics = ClaudeProvider.parseUsage(try JSON(string: legacy))
        #expect(metrics.map(\.id) == ["claude.five_hour", "claude.seven_day"])
        #expect(metrics.first?.usedPercent == 12.5)
    }

    @Test func credentialsAndPlan() {
        let blob = #"{"claudeAiOauth":{"accessToken":"t","expiresAt":1790392129525,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
        let credentials = ClaudeProvider.parseCredentials(Data(blob.utf8))
        #expect(credentials?.expiresAt == Date(timeIntervalSince1970: 1_790_392_129.525))
        #expect(ClaudeProvider.planName(subscription: "max", tier: "default_claude_max_20x") == "Max 20x")
        #expect(ClaudeProvider.planName(subscription: "pro", tier: nil) == "Pro")
    }
}

@Suite("ChatGPT")
struct ChatGPTParsingTests {
    @Test func weeklyOnlyPlan() throws {
        let response = """
        {"plan_type": "pro", "rate_limit": {"allowed": true, "limit_reached": false,
          "primary_window": {"used_percent": 4, "limit_window_seconds": 604800, "reset_after_seconds": 511907, "reset_at": 1790875999},
          "secondary_window": null}, "additional_rate_limits": null}
        """
        let metrics = ChatGPTProvider.parseUsage(try JSON(string: response))
        #expect(metrics.count == 1)
        #expect(metrics[0].title == "Weekly")
        #expect(metrics[0].usedPercent == 4)
        #expect(metrics[0].resetsAt == Date(timeIntervalSince1970: 1_790_875_999))
    }

    @Test func sessionAndWeeklyAreOrderedShortestFirst() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let response = """
        {"rate_limit": {
          "primary_window": {"used_percent": 70, "limit_window_seconds": 604800, "reset_after_seconds": 100},
          "secondary_window": {"used_percent": 20, "limit_window_seconds": 18000, "reset_after_seconds": 50}},
         "additional_rate_limits": [{"limit_name": "GPT-6", "rate_limit": {"primary_window": {"used_percent": 9, "limit_window_seconds": 604800}}}]}
        """
        let metrics = ChatGPTProvider.parseUsage(try JSON(string: response), now: now)
        #expect(metrics.map(\.title) == ["5-hour", "Weekly", "Weekly · GPT-6"])
        #expect(metrics[0].resetsAt == now.addingTimeInterval(50))
    }
}

@Suite("Cursor")
struct CursorParsingTests {
    let usage = """
    {"billingCycleStart": "1789316766000", "billingCycleEnd": "1791908766000",
     "planUsage": {"totalSpend": 37538, "includedSpend": 37538, "remaining": 2462, "limit": 40000,
       "autoPercentUsed": 10.427666666666667, "apiPercentUsed": 25.019999999999996, "totalPercentUsed": 11.55},
     "enabled": true}
    """
    let grokBot = """
    {"currentPeriodStart": "2026-09-23T05:04:00.623Z", "nextResetTimestampUtc": "2026-09-30T05:04:00.623Z",
     "usagePercent": 22.927172, "hasAvailableUsage": true, "hasNonZeroIncludedLimit": true,
     "grokPlanLabel": "Grok Bot Plan", "cursorPlanName": "Ultra"}
    """

    @Test func readsBothPoolsAndGrokBot() throws {
        let metrics = CursorProvider.parse(usage: try JSON(string: usage), grokBot: try JSON(string: grokBot))
        #expect(metrics.map(\.title) == ["Grok & Composer", "Other models", "Grok Bot"])
        #expect(Int(metrics[0].usedPercent.rounded()) == 10)
        #expect(Int(metrics[1].usedPercent.rounded()) == 25)
        #expect(metrics[0].resetsAt == Date(timeIntervalSince1970: 1_791_908_766))
        #expect(metrics[2].resetsAt == ISODate.parse("2026-09-30T05:04:00.623Z"))
    }

    @Test func grokBotWithoutIncludedLimitIsHidden() throws {
        let noLimit = #"{"usagePercent": 0, "includedLimitZero": true}"#
        let metrics = CursorProvider.parse(usage: try JSON(string: usage), grokBot: try JSON(string: noLimit))
        #expect(!metrics.contains { $0.id == "cursor.grokbot" })
    }

    @Test func fallsBackToSpendWhenPoolsMissing() throws {
        let legacy = #"{"billingCycleEnd": "1791908766000", "planUsage": {"totalSpend": 1000, "limit": 2000}}"#
        let metrics = CursorProvider.parse(usage: try JSON(string: legacy), grokBot: nil)
        #expect(metrics.count == 1)
        #expect(metrics[0].usedPercent == 50)
        #expect(metrics[0].detail == "$10 / $20")
    }
}

@Suite("Devin")
struct DevinParsingTests {
    @Test func weeklyQuotaWithHiddenDaily() throws {
        let response = """
        {"userStatus": {"planStatus": {"planStart": "2026-09-09T17:45:23Z", "planEnd": "2026-10-09T17:45:23Z",
          "availablePromptCredits": -1, "dailyQuotaRemainingPercent": 100, "weeklyQuotaRemainingPercent": 13,
          "overageBalanceMicros": "4785278", "dailyQuotaResetAtUnix": "1790409600", "weeklyQuotaResetAtUnix": "1790496000",
          "planInfo": {"planName": "Max", "hideDailyQuota": true, "billingStrategy": "BILLING_STRATEGY_QUOTA"}}}}
        """
        let parsed = DevinProvider.parse(try JSON(string: response))
        #expect(parsed.plan == "Max")
        #expect(parsed.metrics.map(\.title) == ["Weekly"])
        #expect(parsed.metrics[0].usedPercent == 87)
        #expect(parsed.metrics[0].resetsAt == Date(timeIntervalSince1970: 1_790_496_000))
        #expect(parsed.note == "Extra balance $4.79")
    }

    @Test func omittedPercentWithResetMeansExhausted() throws {
        // proto3 JSON drops zero values, so a fully used quota arrives without its percentage.
        let response = #"{"userStatus": {"planStatus": {"weeklyQuotaResetAtUnix": "1790496000", "dailyQuotaRemainingPercent": 40, "dailyQuotaResetAtUnix": "1790409600"}}}"#
        let parsed = DevinProvider.parse(try JSON(string: response))
        #expect(parsed.metrics.map(\.id) == ["devin.daily", "devin.weekly"])
        #expect(parsed.metrics.map(\.usedPercent) == [60, 100])
    }
}

@Suite("Amp")
struct AmpParsingTests {
    let now = ISODate.parse("2026-09-25T19:30:00Z")!

    @Test func paidTierAgentAndOrbPools() {
        let text = """
        Signed in as someone@example.com (someone)
        Amp Megawatt Tier: agent usage $19.27 of $20 remaining (96%), orb usage 474.7h of 750h a1.small orb hours remaining (63%) - period 2026-09-18 to 2026-10-18, resets upon renewal in 22 days
        Individual credits: $8.94 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings
        """
        let parsed = AmpProvider.parse(displayText: text, now: now)
        #expect(parsed.plan == "Megawatt")
        #expect(parsed.metrics.map(\.title) == ["AI model", "Orb"])
        #expect(abs(parsed.metrics[0].usedPercent - 3.65) < 0.01)
        #expect(abs(parsed.metrics[1].usedPercent - 36.7066) < 0.01)
        #expect(parsed.metrics[0].detail == "$19.27 / $20 left")
        #expect(parsed.metrics[1].detail == "475 / 750 h left")
        #expect(parsed.metrics[0].resetsAt == ISODate.parse("2026-10-18T00:00:00Z"))
        #expect(parsed.note == "Credits $8.94")
    }

    @Test func markdownVariantParsesTheSame() {
        let text = "**Amp Megawatt Tier:** agent usage $5 of $20 remaining (25%), orb usage 0h of 750h a1.small orb hours remaining (0%) - period 2026-09-18 to 2026-10-18"
        let parsed = AmpProvider.parse(displayText: text, now: now)
        #expect(parsed.metrics.map(\.usedPercent) == [75, 100])
    }

    @Test func freeTier() throws {
        let text = "Signed in as a@b.c\nAmp Free: $7.90/$10 remaining (replenishes +$0.42/hour)"
        let parsed = AmpProvider.parse(displayText: text, now: now)
        #expect(parsed.plan == "Free")
        #expect(abs(parsed.metrics[0].usedPercent - 21) < 0.001)
        let refill = try #require(parsed.metrics[0].resetsAt)
        #expect(abs(refill.timeIntervalSince(now) - 5 * 3_600) < 1)
    }
}

@Suite("Formatting & summary")
struct FormattingTests {
    @Test func percentAndDurations() {
        #expect(UsageFormat.percent(69.4) == "69%")
        #expect(UsageFormat.percent(0.3) == "<1%")
        #expect(UsageFormat.percent(130) == "100%")
        #expect(UsageFormat.duration(4 * 3_600 + 48 * 60) == "4h 48m")
        #expect(UsageFormat.duration(30 * 3_600) == "1d 6h")
        #expect(UsageFormat.duration(22 * 86_400 + 5 * 3_600) == "22d")
        #expect(UsageFormat.duration(20) == "1m")
        #expect(UsageFormat.dollars(20) == "$20")
        #expect(UsageFormat.dollars(4.785278) == "$4.79")
    }

    @Test func isoDatesWithMicroseconds() {
        #expect(ISODate.parse("2026-09-26T00:09:59.570238+00:00") == ISODate.parse("2026-09-26T00:09:59.570Z"))
        #expect(ISODate.parse("2026-11-05T07:59:00+00:00") != nil)
        #expect(ISODate.fromUnix(1_791_908_766_000) == Date(timeIntervalSince1970: 1_791_908_766))
    }

    @Test func resetWindowsReadAsEmpty() {
        let now = Date()
        let metric = UsageMetric(id: "x", title: "x", usedPercent: 80, resetsAt: now.addingTimeInterval(-1), window: .fiveHour)
        #expect(metric.effectivePercent(now: now) == 0)
    }

    @Test func mostCriticalPicksHighestUsage() {
        let now = Date()
        let states: [ProviderID: ProviderState] = [
            .claude: ProviderState(snapshot: ProviderSnapshot(provider: .claude, plan: nil, metrics: [
                UsageMetric(id: "a", title: "a", usedPercent: 69, window: .weekly),
            ])),
            .devin: ProviderState(snapshot: ProviderSnapshot(provider: .devin, plan: nil, metrics: [
                UsageMetric(id: "b", title: "b", usedPercent: 87, window: .weekly),
            ])),
        ]
        let pick = UsageSummary.mostCritical(states, providers: [.claude, .devin], now: now)
        #expect(pick?.provider == .devin)
        #expect(UsageSummary.mostCritical(states, providers: [.claude], now: now)?.percent == 69)
    }

    @Test func tomlAndJWT() {
        let toml = "windsurf_api_key = \"abc\"\napi_server_url = 'https://server.codeium.com'\n[other]\nwindsurf_api_key = \"nope\""
        #expect(SimpleTOML.parse(toml) == ["windsurf_api_key": "abc", "api_server_url": "https://server.codeium.com"])
        // {"exp": 4102444800} → 2100-01-01
        let token = "eyJhbGciOiJub25lIn0.eyJleHAiOjQxMDI0NDQ4MDB9.sig"
        #expect(JWT.expiry(token) == Date(timeIntervalSince1970: 4_102_444_800))
        #expect(!JWT.isExpired(token))
    }
}
