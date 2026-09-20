import Foundation
import Testing
import YakamozCore
@testable import YakamozNetwork

@Suite("NetworkSettings")
@MainActor
struct NetworkSettingsTests {
    @Test("Fresh install shows the documented defaults")
    func defaults() {
        let settings = NetworkSettings(defaults: TestDefaults.make())
        #expect(settings.host == "127.0.0.1")
        #expect(settings.port == 1883)
        #expect(settings.namespace == "gnostic")
        #expect(settings.identity == "yakamoz")
        #expect(settings.username == "")
        #expect(settings.isEnabled == false)
        #expect(settings.validate().isEmpty)
    }

    @Test("Non-secret fields persist and reload")
    func persistenceRoundTrip() {
        let defaults = TestDefaults.make()
        let settings = NetworkSettings(defaults: defaults)
        settings.host = "broker.example"
        settings.port = 8883
        settings.namespace = "team"
        settings.identity = "yakamoz-dev"
        settings.username = "operator"
        settings.isEnabled = true
        settings.persist()

        let reloaded = NetworkSettings(defaults: defaults)
        #expect(reloaded.snapshot == settings.snapshot)
        #expect(reloaded.isEnabled == true)
    }

    @Test("validate reports each field problem")
    func validationReportsEveryProblem() {
        let settings = NetworkSettings(defaults: TestDefaults.make())
        settings.host = "   "
        settings.port = 0
        settings.namespace = ""
        settings.identity = ""

        let issues = settings.validate()
        #expect(issues.contains(.emptyHost))
        #expect(issues.contains(.invalidPort(0)))
        #expect(issues.contains(.emptyNamespace))
        #expect(issues.contains(.emptyIdentity))
    }

    @Test("A password without a username is rejected")
    func passwordRequiresUsername() {
        let settings = NetworkSettings(defaults: TestDefaults.make())
        #expect(settings.validate(password: "pw").contains(.passwordWithoutUsername))

        settings.username = "operator"
        #expect(!settings.validate(password: "pw").contains(.passwordWithoutUsername))
        #expect(!settings.validate(password: nil).contains(.passwordWithoutUsername))
    }

    @Test("Port must be within 1...65535")
    func portBounds() {
        let settings = NetworkSettings(defaults: TestDefaults.make())
        settings.port = 65536
        #expect(settings.validate().contains(.invalidPort(65536)))
        settings.port = 1
        #expect(settings.validate().isEmpty)
    }

    @Test("Password is written only through the secret store")
    func passwordIsSecret() throws {
        let defaults = TestDefaults.make()
        let secrets = FakeSecretStore()
        let settings = NetworkSettings(defaults: defaults)

        try settings.applyPassword("  s3cret  ", secrets: secrets)

        #expect(try secrets.read(account: NetworkSettings.passwordAccount) == "s3cret")
        let persistedStrings = defaults.dictionaryRepresentation().values.compactMap { $0 as? String }
        #expect(!persistedStrings.contains("s3cret"))
    }

    @Test("A blank password clears the stored secret")
    func blankPasswordClears() throws {
        let secrets = FakeSecretStore()
        let settings = NetworkSettings(defaults: TestDefaults.make())

        try settings.applyPassword("s3cret", secrets: secrets)
        try settings.applyPassword("   ", secrets: secrets)

        #expect(try secrets.read(account: NetworkSettings.passwordAccount) == nil)
        #expect(try settings.storedPassword(secrets: secrets) == nil)
    }

    @Test("Broker configuration folds in credentials and normalizes blanks")
    func brokerConfiguration() throws {
        let secrets = FakeSecretStore()
        let settings = NetworkSettings(defaults: TestDefaults.make())
        settings.host = " broker.local "
        settings.username = " operator "
        settings.namespace = "team"
        settings.isEnabled = true
        try settings.applyPassword("pw", secrets: secrets)

        let configuration = try settings.brokerConfiguration(secrets: secrets)
        #expect(configuration.host == "broker.local")
        #expect(configuration.username == "operator")
        #expect(configuration.password == "pw")
        #expect(configuration.namespace == "team")
        #expect(configuration.isEnabled)
    }

    @Test("Blank credentials normalize to nil")
    func blankCredentialsNormalize() throws {
        let secrets = FakeSecretStore()
        let settings = NetworkSettings(defaults: TestDefaults.make())

        let configuration = try settings.brokerConfiguration(secrets: secrets)
        #expect(configuration.username == nil)
        #expect(configuration.password == nil)
    }
}
