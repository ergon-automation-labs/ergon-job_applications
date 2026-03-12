ExUnit.start()

# Define Mox mocks for store behaviours
Mox.defmock(BotArmyJobApplications.ResumeStoreMock, for: BotArmyJobApplications.ResumeStoreBehaviour)
Mox.defmock(BotArmyJobApplications.ListingStoreMock, for: BotArmyJobApplications.ListingStoreBehaviour)

# Set up global Mox defaults
Mox.set_mox_global()
