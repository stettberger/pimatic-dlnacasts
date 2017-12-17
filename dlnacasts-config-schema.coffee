# #my-plugin configuration options
# Declare your config option for your plugin here.
module.exports = {
  title: "DLNACasts Plugin"
  type: "object"
  properties:
    timeout:
      description: "DLNA Scan Interval (seconds)"
      type: "number"
      default: 60
}
