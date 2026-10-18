import CryptoKit
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

    @Test func readsCursorModelsAndGrokBot() throws {
        let metrics = CursorProvider.parse(usage: try JSON(string: usage), grokBot: try JSON(string: grokBot))
        #expect(metrics.map(\.title) == ["Grok & Composer", "Grok Bot"])
        #expect(metrics.map(\.id) == ["cursor.auto", "cursor.grokbot"])
        #expect(Int(metrics[0].usedPercent.rounded()) == 10)
        #expect(metrics[0].window == .monthly)
        #expect(metrics[0].resetsAt == Date(timeIntervalSince1970: 1_791_908_766))
        #expect(metrics[1].resetsAt == ISODate.parse("2026-09-30T05:04:00.623Z"))
    }

    @Test func weeklySubscriptionUsesTheIncludedReset() throws {
        let plan = """
        {"isMerged": true, "planInfo": {"planName": "Pro",
          "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_WEEKLY", "includedUsageResetsAt": "1790500000000"}}
        """
        let parsed = try JSON(string: plan)
        let metrics = CursorProvider.parse(usage: try JSON(string: usage), grokBot: try JSON(string: grokBot), plan: parsed)
        #expect(metrics.map(\.title) == ["Weekly"])
        #expect(metrics.map(\.id) == ["cursor.weekly"])
        #expect(metrics[0].window == .weekly)
        #expect(metrics[0].usedPercent == 11.55)
        #expect(metrics[0].resetsAt == Date(timeIntervalSince1970: 1_790_500_000))
        #expect(CursorProvider.planName(plan: parsed, grokBot: nil, membership: "ultra") == "Pro")
    }

    @Test func unifiedFlagUsesTheSharedPoolWithoutASecondQuota() throws {
        let sand = """
        {"isUnified": true, "usagePercent": 40, "nextResetTimestampUtc": "2026-09-30T05:04:00.623Z",
         "hasNonZeroIncludedLimit": true}
        """
        let metrics = CursorProvider.parse(usage: try JSON(string: usage), grokBot: try JSON(string: sand), plan: nil)
        #expect(metrics.map(\.title) == ["Weekly"])
        #expect(metrics[0].usedPercent == 11.55)
        #expect(metrics[0].resetsAt == ISODate.parse("2026-09-30T05:04:00.623Z"))
    }

    @Test func numericWeeklyPeriodUsesTheSharedIncludedPool() throws {
        let plan = #"{"planInfo": {"includedUsagePeriod": 2, "includedUsageResetsAt": 1790500000000}}"#
        let metrics = CursorProvider.parse(usage: try JSON(string: usage), grokBot: nil, plan: try JSON(string: plan))
        #expect(metrics.map(\.title) == ["Weekly"])
        #expect(metrics[0].usedPercent == 11.55)
        #expect(metrics[0].resetsAt == Date(timeIntervalSince1970: 1_790_500_000))
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
        #expect(parsed.balance?.title == "Extra usage")
        #expect(parsed.balance.map { UsageFormat.dollars($0.amount) } == "$4.79")
    }

    @Test func noBalanceWithoutOverage() throws {
        let response = #"{"userStatus": {"planStatus": {"weeklyQuotaRemainingPercent": 50, "weeklyQuotaResetAtUnix": "1790496000"}}}"#
        #expect(DevinProvider.parse(try JSON(string: response)).balance == nil)
    }

    @Test func omittedPercentWithResetMeansExhausted() throws {
        // proto3 JSON drops zero values, so a fully used quota arrives without its percentage.
        let response = #"{"userStatus": {"planStatus": {"weeklyQuotaResetAtUnix": "1790496000", "dailyQuotaRemainingPercent": 40, "dailyQuotaResetAtUnix": "1790409600"}}}"#
        let parsed = DevinProvider.parse(try JSON(string: response))
        #expect(parsed.metrics.map(\.id) == ["devin.daily", "devin.weekly"])
        #expect(parsed.metrics.map(\.usedPercent) == [60, 100])
    }
}

@Suite("Antigravity")
struct AntigravityParsingTests {
    let response = """
    {
      "groups": [
        {
          "buckets": [
            {"bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly",
             "resetTime": "2026-10-08T06:23:55Z", "remainingFraction": 0.82},
            {"bucketId": "gemini-5h", "displayName": "Five Hour Limit Remaining", "window": "5h",
             "resetTime": "2026-10-01T11:23:55Z", "remainingFraction": 0.4}
          ],
          "displayName": "Gemini Models",
          "description": "Models within this group: Gemini Flash, Gemini Pro"
        },
        {
          "buckets": [
            {"bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly",
             "resetTime": "2026-10-08T06:23:55Z", "remainingFraction": 1},
            {"bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "window": "5h",
             "resetTime": "2026-10-01T11:23:55Z", "remainingFraction": 0}
          ],
          "displayName": "Claude and GPT models",
          "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS"
        }
      ],
      "description": "Within each group, models share a weekly limit and a 5-hour limit."
    }
    """

    @Test func geminiCellsThenOtherModelsPool() throws {
        let metrics = AntigravityProvider.parse(quotaSummary: try JSON(string: response))
        #expect(metrics.map(\.title) == ["Gemini 5-hour", "Gemini weekly", "Other models 5-hour", "Other models weekly"])
        #expect(metrics.map(\.group) == [nil, nil, "Other models", "Other models"])
        #expect(metrics.map { $0.usedPercent.rounded() } == [60, 18, 100, 0])
        #expect(metrics[0].resetsAt == ISODate.parse("2026-10-01T11:23:55Z"))
        #expect(metrics[2].detail == "Claude Opus, Claude Sonnet, GPT-OSS")
        #expect(metrics[0].detail == nil)
    }

    @Test func untouchedWindowHasNoReset() throws {
        let metrics = AntigravityProvider.parse(quotaSummary: try JSON(string: response))
        // A full window reports "now + 7 days", which would slide on every refresh.
        #expect(metrics[3].resetsAt == nil)
    }

    @Test func disabledBucketsAreSkipped() throws {
        let json = try JSON(string: #"{"groups": [{"displayName": "Gemini Models", "buckets": [{"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.5, "disabled": true}, {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.5}]}]}"#)
        #expect(AntigravityProvider.parse(quotaSummary: json).map(\.id) == ["antigravity.gemini-weekly"])
    }

    @Test func credentialsAndPlan() throws {
        let blob = #"{"token": {"access_token": "t", "token_type": "Bearer", "refresh_token": "r", "expiry": "2026-10-01T09:46:09.20065+03:00"}, "auth_method": "consumer"}"#
        let credentials = AntigravityProvider.parseCredentials(Data(blob.utf8))
        #expect(credentials?.accessToken == "t")
        #expect(credentials?.expiresAt == ISODate.parse("2026-10-01T06:46:09.200Z"))
        #expect(AntigravityProvider.planName(try JSON(string: #"{"currentTier": {"id": "free-tier", "name": "Antigravity"}}"#)) == "Free")
        #expect(AntigravityProvider.planName(try JSON(string: #"{"currentTier": {"id": "free-tier"}, "paidTier": {"id": "g1-ultra-lite-tier", "name": "Google AI Ultra"}}"#)) == "Ultra")
        #expect(AntigravityProvider.planName(try JSON(string: "{}")) == nil)
    }
}

@Suite("Gemini")
struct GeminiParsingTests {
    let response = """
    {
      "userTier": "TIER_NEON",
      "usage": [
        {
          "budgetPoolType": "GXU_WEEKLY",
          "gxu": {
            "windowRefreshesAt": "2026-10-20T18:30:00.559555Z",
            "pctUsed": 0.2936904,
            "title": "Weekly limit"
          }
        },
        {
          "budgetPoolType": "GXU_FIVE_HOURLY",
          "gxu": {
            "windowRefreshesAt": "2026-10-18T20:30:00.559383Z",
            "pctUsed": 0,
            "title": "Current usage"
          }
        }
      ]
    }
    """

    @Test func fiveHourThenWeeklyAndPlanMapping() throws {
        let parsed = GeminiProvider.parse(usageInfo: try JSON(string: response))
        #expect(parsed.plan == "Ultra")
        #expect(parsed.metrics.map(\.id) == ["gemini.fiveHour", "gemini.weekly"])
        #expect(parsed.metrics.map(\.title) == ["5-hour", "Weekly"])
        #expect(parsed.metrics[0].usedPercent == 0)
        #expect(parsed.metrics[0].resetsAt == nil)
        #expect(abs(parsed.metrics[1].usedPercent - 29.36904) < 0.001)
        #expect(parsed.metrics[1].resetsAt == ISODate.parse("2026-10-20T18:30:00.559Z"))
    }

    @Test func tierMappingsAndOverageCredits() throws {
        #expect(GeminiProvider.planName("TIER_NEON") == "Ultra")
        #expect(GeminiProvider.planName("TIER_ULTRA") == "Ultra")
        #expect(GeminiProvider.planName("TIER_PRO") == "Pro")
        #expect(GeminiProvider.planName("TIER_PREMIUM") == "Pro")
        #expect(GeminiProvider.planName("TIER_HELIUM") == "Plus")
        #expect(GeminiProvider.planName("TIER_LITE") == "Plus")
        #expect(GeminiProvider.planName("TIER_BASIC") == "Free")
        #expect(GeminiProvider.planName(nil) == nil)

        let withCredits = """
        {
          "userTier": "TIER_ULTRA",
          "usage": [
            {"budgetPoolType": "GXU_FIVE_HOURLY", "gxu": {"pctUsed": 0.5, "windowRefreshesAt": "2026-10-18T20:30:00Z"}},
            {"budgetPoolType": "OVERAGE_CREDITS", "credits": {"creditsRemaining": 450, "useOverageAiCredits": true}}
          ]
        }
        """
        let parsed = GeminiProvider.parse(usageInfo: try JSON(string: withCredits))
        #expect(parsed.plan == "Ultra")
        #expect(parsed.metrics.first?.detail == "450 credits left")
    }

    @Test func containerAndKeystoreDecryption() throws {
        // Build a synthetic Keystore protobuf: field 1 = magic (1), field 2 = KeyData { 1: 1, 2: 1, 4: <32-byte key> }
        let key = Data((0..<32).map(UInt8.init))
        var keyData = Data([0x08, 0x01, 0x10, 0x01, 0x22, 0x20])
        keyData.append(key)
        var keystore = Data([0x08, 0x01, 0x12, UInt8(keyData.count)])
        keystore.append(keyData)

        #expect(GeminiProvider.extractCredentialsKey(from: keystore) == key)

        // Build StoredCredentialData protobuf with field 4 (refresh_token) = "1//test-refresh-token"
        let tokenBytes = Data("1//test-refresh-token".utf8)
        var plaintext = Data([0x22, UInt8(tokenBytes.count)])
        plaintext.append(tokenBytes)

        let nonce = Data((0..<12).map { UInt8($0 + 10) })
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce))
        var preamble = Data([0x08, 0x01, 0x10, 0x01, 0x18, 0x01, 0x22, 0x0c])
        preamble.append(nonce)

        var container = Data(GeminiProvider.containerMagic)
        var preambleLen = UInt32(preamble.count).littleEndian
        withUnsafeBytes(of: &preambleLen) { container.append(contentsOf: $0) }
        container.append(preamble)
        container.append(sealed.ciphertext)
        container.append(sealed.tag)

        let decrypted = try GeminiProvider.decryptContainer(container, key: key)
        #expect(GeminiProvider.parseRefreshToken(from: decrypted) == "1//test-refresh-token")
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
        #expect(parsed.balance == UsageBalance(title: "Credits", amount: 8.94))
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
        #expect(UsageFormat.percent(0.3) == "0%")
        #expect(UsageFormat.percent(0.6) == "1%")
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
