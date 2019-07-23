## Unit tests in ../../test/unit/browsers/chrome_spec

_         = require("lodash")
os        = require("os")
path      = require("path")
Promise   = require("bluebird")
CRI       = require('chrome-remote-interface')
la        = require('lazy-ass')
check     = require('check-more-types')
extension = require("@packages/extension")
debug     = require("debug")("cypress:server:browsers")
plugins   = require("../plugins")
fs        = require("../util/fs")
appData   = require("../util/app_data")
utils     = require("./utils")
protocol  = require("./protocol")

LOAD_EXTENSION = "--load-extension="
CHROME_VERSIONS_WITH_BUGGY_ROOT_LAYER_SCROLLING = "66 67".split(" ")
CHROME_VERSION_INTRODUCING_PROXY_BYPASS_ON_LOOPBACK = 72

pathToExtension = extension.getPathToExtension()
pathToTheme     = extension.getPathToTheme()

defaultArgs = [
  "--test-type"
  "--ignore-certificate-errors"
  "--start-maximized"
  "--silent-debugger-extension-api"
  "--no-default-browser-check"
  "--no-first-run"
  "--noerrdialogs"
  "--enable-fixed-layout"
  "--disable-popup-blocking"
  "--disable-password-generation"
  "--disable-save-password-bubble"
  "--disable-single-click-autofill"
  "--disable-prompt-on-repos"
  "--disable-background-timer-throttling"
  "--disable-renderer-backgrounding"
  "--disable-renderer-throttling"
  "--disable-restore-session-state"
  "--disable-translate"
  "--disable-new-profile-management"
  "--disable-new-avatar-menu"
  "--allow-insecure-localhost"
  "--reduce-security-for-testing"
  "--enable-automation"
  "--disable-infobars"
  "--disable-device-discovery-notifications"

  ## https://github.com/cypress-io/cypress/issues/2376
  "--autoplay-policy=no-user-gesture-required"

  ## http://www.chromium.org/Home/chromium-security/site-isolation
  ## https://github.com/cypress-io/cypress/issues/1951
  "--disable-site-isolation-trials"

  ## the following come frome chromedriver
  ## https://code.google.com/p/chromium/codesearch#chromium/src/chrome/test/chromedriver/chrome_launcher.cc&sq=package:chromium&l=70
  "--metrics-recording-only"
  "--disable-prompt-on-repost"
  "--disable-hang-monitor"
  "--disable-sync"
  ## this flag is causing throttling of XHR callbacks for
  ## as much as 30 seconds. If you VNC in and open dev tools or
  ## click on a button, it'll "instantly" work. with this
  ## option enabled, it will time out some of our tests in circle
  # "--disable-background-networking"
  "--disable-web-resources"
  "--safebrowsing-disable-auto-update"
  "--safebrowsing-disable-download-protection"
  "--disable-client-side-phishing-detection"
  "--disable-component-update"
  "--disable-default-apps"

  ## These flags are for webcam/WebRTC testing
  ## https://github.com/cypress-io/cypress/issues/2704
  "--use-fake-ui-for-media-stream"
  "--use-fake-device-for-media-stream"
]

pluginsBeforeBrowserLaunch = (browser, args) ->
  ## bail if we're not registered to this event
  return args if not plugins.has("before:browser:launch")

  plugins.execute("before:browser:launch", browser, args)
  .then (newArgs) ->
    debug("got user args for 'before:browser:launch'", newArgs)

    ## reset args if we got 'em
    return newArgs ? args

_normalizeArgExtensions = (dest, args) ->
  loadExtension = _.find args, (arg) ->
    arg.includes(LOAD_EXTENSION)

  if loadExtension
    args = _.without(args, loadExtension)

    ## form into array, enabling users to pass multiple extensions
    userExtensions = loadExtension.replace(LOAD_EXTENSION, "").split(",")

  extensions = [].concat(userExtensions, dest, pathToTheme)

  args.push(LOAD_EXTENSION + _.compact(extensions).join(","))

  args

## we now store the extension in each browser profile
_removeRootExtension = ->
  fs
  .removeAsync(appData.path("extensions"))
  .catchReturn(null) ## noop if doesn't exist fails for any reason

## https://github.com/cypress-io/cypress/issues/2048
_disableRestorePagesPrompt = (userDir) ->
  prefsPath = path.join(userDir, "Default", "Preferences")

  fs.readJson(prefsPath)
  .then (preferences) ->
    if profile = preferences.profile
      if profile["exit_type"] != "Normal" or profile["exited_cleanly"] isnt true
        debug("cleaning up unclean exit status")

        profile["exit_type"] = "Normal"
        profile["exited_cleanly"] = true

        fs.writeJson(prefsPath, preferences)
  .catch ->

# After the browser has been opened, we can connect to
# its remote interface via a websocket.
_connectToChromeRemoteInterface = (port) ->
  la(check.userPort(port), "expected port number to connect CRI to", port)

  debug("connecting to Chrome remote interface at random port %d", port)
  # at first the tab will be blank "new tab"
  protocol.getWsTargetFor(port)
  .then (wsUrl) ->
    debug("received wsUrl %s for port %d", wsUrl, port)
    # TODO decide later how and where to keep the wsUrl and the CRI client
    # use the websocket connection to create Chrome remote interface client
    client = CRI({
      target: wsUrl,
      local: true
    })

_maybeRecordVideo = (options) ->
  (client) ->
    if options.screencastFrame
      debug('starting screencast')
      debug('screencast meta info %o', client.Page.ScreencastFrameMetadata)

      client.Page.screencastFrame(options.screencastFrame)
      client.Page.startScreencast({
        format: 'jpeg'
      })
    client

# a utility function that navigates to the given URL
# once Chrome remote interface client is passed to it.
_navigateUsingCRI = (url) ->
  la(check.url(url), "missing url to navigate to", url)

  (client) ->
    la(client, "could not get CRI client")
    debug("received CRI client")
    debug('navigating to page %s', url)
    # when opening the blank page and trying to navigate
    # the focus gets lost. Restore it first
    client.Page.bringToFront()
    # .then ->
    #   debug('starting screencast')
    #   debug('screencast meta info %o', client.Page.ScreencastFrameMetadata)
      # client.Page.screencastFrame (e) ->
      #   debug('received screencastFrame %d %o', e.sessionId, e.metadata)
      # client.Page.startScreencast({
      #   format: 'jpeg'
      # })
    .then ->
      client.Page.navigate({ url })

module.exports = {
  #
  # tip:
  #   by adding utility functions that start with "_"
  #   as methods here we can easily stub them from our unit tests
  #

  _normalizeArgExtensions

  _removeRootExtension

  _connectToChromeRemoteInterface

  _maybeRecordVideo

  _navigateUsingCRI

  _writeExtension: (browser, isTextTerminal, proxyUrl, socketIoRoute) ->
    ## get the string bytes for the final extension file
    extension.setHostAndPath(proxyUrl, socketIoRoute)
    .then (str) ->
      extensionDest = utils.getExtensionDir(browser, isTextTerminal)
      extensionBg   = path.join(extensionDest, "background.js")

      ## copy the extension src to the extension dist
      utils.copyExtension(pathToExtension, extensionDest)
      .then ->
        ## and overwrite background.js with the final string bytes
        fs.writeFileAsync(extensionBg, str)
      .return(extensionDest)

  _getArgs: (options = {}) ->
    _.defaults(options, {
      browser: {}
    })

    args = [].concat(defaultArgs)

    if os.platform() is "linux"
      args.push("--disable-gpu")
      args.push("--no-sandbox")

    if ua = options.userAgent
      args.push("--user-agent=#{ua}")

    if ps = options.proxyServer
      args.push("--proxy-server=#{ps}")

    if options.chromeWebSecurity is false
      args.push("--disable-web-security")
      args.push("--allow-running-insecure-content")

    ## prevent AUT shaking in 66 & 67, but flag breaks chrome in 68+
    ## https://github.com/cypress-io/cypress/issues/2037
    ## https://github.com/cypress-io/cypress/issues/2215
    ## https://github.com/cypress-io/cypress/issues/2223
    { majorVersion } = options.browser
    if majorVersion in CHROME_VERSIONS_WITH_BUGGY_ROOT_LAYER_SCROLLING
      args.push("--disable-blink-features=RootLayerScrolling")

    ## https://chromium.googlesource.com/chromium/src/+/da790f920bbc169a6805a4fb83b4c2ab09532d91
    ## https://github.com/cypress-io/cypress/issues/1872
    if majorVersion >= CHROME_VERSION_INTRODUCING_PROXY_BYPASS_ON_LOOPBACK
      args.push("--proxy-bypass-list=<-loopback>")

    args

  open: (browser, url, options = {}, automation) ->
    { isTextTerminal } = options

    userDir = utils.getProfileDir(browser, isTextTerminal)

    Promise
    .try =>
      args = @_getArgs(options)

      Promise.all([
        ## ensure that we have a clean cache dir
        ## before launching the browser every time
        utils.ensureCleanCache(browser, isTextTerminal),

        pluginsBeforeBrowserLaunch(options.browser, args),

        utils.getPort()
      ])
    .spread (cacheDir, args, port) =>
      Promise.all([
        @_writeExtension(
          browser,
          isTextTerminal,
          options.proxyUrl,
          options.socketIoRoute
        ),
        _removeRootExtension(),
        _disableRestorePagesPrompt(userDir),
      ])
      .spread (extDest) ->
        ## normalize the --load-extensions argument by
        ## massaging what the user passed into our own
        args = _normalizeArgExtensions(extDest, args)

        ## this overrides any previous user-data-dir args
        ## by being the last one
        args.push("--user-data-dir=#{userDir}")
        args.push("--disk-cache-dir=#{cacheDir}")
        debug("get random port %d for remote debugging", port)
        args.push("--remote-debugging-port=#{port}")

        debug("launch in chrome: %s, %s", url, args)

        # FIRST load the blank page
        # first allows us to connect the remote interface,
        # start video recording and then
        # we will load the actual page
        utils.launch(browser, null, args)
        # utils.launch(browser, url, args)

      .tap =>
        # SECOND connect to the Chrome remote interface
        # and when the connection is ready
        # navigate to the actual url
        @_connectToChromeRemoteInterface(port)
        .then @_maybeRecordVideo(options)
        .then @_navigateUsingCRI(url)
}
