-- Managed by surface11-camera. Requires WirePlumber 0.5.18 permission managers.
-- Extend the selected manager so portal/sandbox checks on public cameras stay
-- intact. The native nodes have a non-Camera media.role to avoid an overlapping
-- portal grant (permission-manager matches are combined with bitwise OR).
local log = Log.open_topic ("surface11-camera")
local configured = {}

SimpleEventHook {
  name = "surface11-camera/private-backends",
  after = "client/find-default-access",
  before = "client/apply-access",
  interests = {
    EventInterest { Constraint { "event.type", "=", "select-access" } },
  },
  execute = function (event)
    local pm = event:get_data ("permission-manager")
    if event:get_data ("default-permissions") ~= nil or pm == nil then
      log:warning ("Client uses direct permissions; Surface backend isolation cannot be applied")
      return
    end
    if configured[pm] then return end
    configured[pm] = true
    pm:add_interest_match (
      function (_, client, _)
        local name = client:get_property ("application.name")
        local binary = client:get_property ("application.process.binary")
        if name == "surface11-camera-relay" or binary == "wireplumber" then
          return Perm.ALL
        end
        return Perm.NONE
      end,
      Interest {
        type = "node",
        Constraint { "node.name", "c",
          "libcamera_input.__SB_.PC00.I2C5.CAMF",
          "libcamera_input.__SB_.PC00.I2C3.CAMR" },
      }
    )
    pm:update_permissions ()
  end,
}:register ()
