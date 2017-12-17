# #Plugin template

# This is an plugin template and mini tutorial for creating pimatic plugins. It will explain the
# basics of how the plugin system works and how a plugin should look like.

# ##The plugin code

# Your plugin must export a single function, that takes one argument and returns a instance of
# your plugin class. The parameter is an envirement object containing all pimatic related functions
# and classes. See the [startup.coffee](http://sweetpi.de/pimatic/docs/startup.html) for details.
module.exports = (env) ->

  # ###require modules included in pimatic
  # To require modules that are included in pimatic use `env.require`. For available packages take
  # a look at the dependencies section in pimatics package.json

  # Require the  bluebird promise library
  Promise = env.require 'bluebird'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'

  # Include you own depencies with nodes global require function:
  #
  dlnacasts = require 'dlnacasts'
  MediaRenderer = require 'upnp-mediarenderer-client'
  t = env.require('decl-api').types
  __ = env.require("i18n").__
  _ = env.require('lodash')
  S = env.require('string')
  M = env.matcher


  #

  # ###MyPlugin class
  # Create a class that extends the Plugin class and implements the following functions:
  class DLNACastsPlugin extends env.plugins.Plugin

    # ####init()
    # The `init` function is called by the framework to ask your plugin to initialise.
    #
    # #####params:
    #  * `app` is the [express] instance the framework is using.
    #  * `framework` the framework itself
    #  * `config` the properties the user specified as config for your plugin in the `plugins`
    #     section of the config.json file
    #
    #
    init: (app, @framework, @config) =>
      deviceConfigDef = require("./device-config-schema")

      @devices = []
      @framework.deviceManager.registerDeviceClass('DLNARenderer', {
        configDef: deviceConfigDef.DLNARenderer,
        createCallback: (deviceConfig, lastState) =>
          device = new DLNARenderer(deviceConfig, lastState, @framework)
          @devices.push(device)
          return device
      })
      @framework.ruleManager.addActionProvider(new StreamActionProvider(@framework))


      @checkInterval = @config.checkInterval or 10

      setInterval ( => @check() ), @checkInterval * 1000
      @check()


    check: =>
      env.logger.debug('DLNACastsPlugin', "issued update")
      list = dlnacasts()
      @players = []
      list.on('update', (player) =>
        @players.push(player)
        player.client = new MediaRenderer(player.xml)
        #player.status((state) =>
        #  console.log(player._status, "asd")
        #)
      )
      list.update()
      setTimeout ( => @match()), 5 * 1000

    match: =>
       names = @players.map (p) -> p.name
       env.logger.debug('DLNACastsPlugin', "match player list to device list: " + names)

       for device in @devices
         found = null
         for player in @players
           if (player.name == device.identifier || player.host == device.identifier)
              found = player
         device._update_player(found)


  class DLNARenderer extends env.devices.PresenceSensor
    actions:
      stream_url:
        description: "Stream a URL on the renderer"
        params:
          url:
            type: t.string
      stop:
         description: "Stop the Player"
      pause:
         description: "Pause the Player"
      play:
         description: "Start playback"

    constructor: (@config, lastState, @framework) ->
      env.logger.info('DLNARenderer', @config, lastState)

      @id = @config.id
      @name = @config.name
      @identifier = @config.identifier
      @_presence = lastState?.presence?.value or false

      @player = null

      super()

    destroy: ->
      super()

    _update_player: (player) =>
      @player = player
      if (@player)
          # needed all devices and no error
          # or not needed all and min one ok
          # check succeeded
          env.logger.debug "#{@id} is present"

          # set as present
          @_setPresence true
      else
          # check failed
          env.logger.debug "#{@id} is absent"

          # set as absent
          @_setPresence false

    stream_url: (url) ->
      if !@_presence
        return Promise.reject(@name + ' is not present. Cannot play: ' + url)
      player = @player
      return new Promise((resolve, reject) =>
        try
          player.stop( =>
            player.play(url,  {type: 'audio/mp3'},
                        => resolve("DONE")))
        catch e
          reject(e)
      )

    execute_on_player: (cb) ->
      if !@_presence or @player is null
        return Promise.reject(@name + ' is not present.')
      player = @player
      return new Promise((resolve, reject) =>
        try
          cb(player, => resolve("DONE"))
        catch e
          reject(e)
      )

    stop: -> @execute_on_player( (player, cb) => player.stop(cb) )
    play: -> @execute_on_player( (player, cb) => player.resume(cb) )
    pause: -> @execute_on_player( (player, cb) => player.pause(cb) )


  class StreamActionProvider extends env.actions.ActionProvider

    constructor: (@framework) ->

    # ### parseAction()
    ###
    Parses the above actions.
    ###
    parseAction: (input, context) =>

      stream_action_devices = _(@framework.deviceManager.devices).values().filter(
        # only match Shutter devices and not media players
        (device) => device.stream_url
      ).value()

      device = null
      match = null
      url = null

      # Try to match the input string with: stop ->
      # Try to match the input string with:
      M(input, context)
        .match('stream ')
        .matchStringWithVars( (next, ts) =>
          next.match(' on ')
            .matchDevice(stream_action_devices, (next, d) =>
              if device? and device.id isnt d.id
                context?.addError(""""#{input.trim()}" is ambiguous.""")
                return
              device = d
              url = ts
              match = next.getFullMatch()
            )
        )

      if match?
        assert device?
        assert url?
        assert typeof match is "string"
        return {
          token: match
          nextInput: input.substring(match.length)
          actionHandler: new StreamActionHandler(@framework, device, url)
        }
      else
        return null

  class StreamActionHandler extends env.actions.ActionHandler

    constructor: (@framework, @device, @url) ->
      assert @device?
      assert @url?

    setup: ->
      @dependOnDevice(@device)
      super()

    ###
    Handles the above actions.
    ###
    _doExecuteAction: (simulate, value) =>
      return (
        if simulate
          __("would stream %s to %s", value, @device.name)
        else
          @device.stream_url(value).then(=>__("play stream %s on %s", value, @device.name))
      )

    # ### executeAction()
    executeAction: (simulate) =>
      @framework.variableManager.evaluateStringExpression(@url).then( (value) =>
        @lastValue = value
        return @_doExecuteAction(simulate, value)
      )


  # ###Finally
  # Create a instance of my plugin
  plugin = new DLNACastsPlugin
  # and return it to the framework.
  return plugin
