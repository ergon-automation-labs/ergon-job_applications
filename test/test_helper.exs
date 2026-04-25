ExUnit.configure(exclude: [:integration, :load, :nats_live])

ExUnit.start()

# Define Mox mocks for store behaviours
Mox.defmock(BotArmyJobApplications.ResumeStoreMock,
  for: BotArmyJobApplications.ResumeStoreBehaviour
)

Mox.defmock(BotArmyJobApplications.ListingStoreMock,
  for: BotArmyJobApplications.ListingStoreBehaviour
)

Mox.defmock(BotArmyJobApplications.ApplicationStoreMock,
  for: BotArmyJobApplications.ApplicationStoreBehaviour
)

# Use private mode so each test process can set its own expectations
Mox.set_mox_private()
