Promise         = require 'bluebird'
EventEmitter    = require 'microemitter'
Encoder         = require 'htmlencode'
Traverse        = require 'traverse'
createId        = require 'hat'
JsPath          = require 'jspath'
Model           = require './model'
ListenerTree    = require './listenertree'
EventBus        = require './eventbus'
OpaqueType      = require './opaquetype'
Signature       = require './signature'
bound           = require './bound'
createBongoName = (resourceName) -> "#{createId 128}.unknown.bongo-#{resourceName}"

do ->
  # mixin the event emitter for the AMQP broker
  Model::mixin require './eventemitter/broker'
  # need these aliases:
  Model::off               = Model::removeListener
  Model::addGlobalListener = Model::on

module.exports = class Bongo extends EventEmitter

  [NOTCONNECTED, CONNECTING, CONNECTED, DISCONNECTED] = [0,1,2,3]
  BATCH_CHUNK_MS = 300

  @dnodeProtocol          = require 'dnode-protocol'
  @dnodeProtocol.Scrubber = require './scrubber'
  @promibackify           = require './promibackify'

  {Store, Scrubber} = @dnodeProtocol
  {slice}           = []

  constructor:(options)->
    EventEmitter this
    { @mq, @getSessionToken, @getUserArea, @fetchName, @resourceName,
      @apiEndpoint, @useWebsockets, @batchRequests, @apiDescriptor } = options
    @useWebsockets ?= no
    @batchRequests ?= yes
    @getUserArea   ?= -> # noop
    @localStore     = new Store
    @remoteStore    = new Store
    @readyState     = NOTCONNECTED
    @stack          = []
    @opaqueTypes  = {}
    @on 'newListener', (event, listener)=>
      if event is 'ready' and @readyState is CONNECTED
        process.nextTick =>
          @emit 'ready'
          @off 'ready'
    @setOutboundTimer()  if @batchRequests
    unless @useWebsockets
      @once 'ready', => process.nextTick @bound 'xhrHandshake'

    @api = @createRemoteApiShims @apiDescriptor

    if @mq?
      @eventBus = new EventBus @mq
      @mq.on 'disconnected', =>
        @disconnectedAt = Date.now()
        @emit 'disconnected'
        @readyState = DISCONNECTED

  bound : bound

  isConnected: -> return @readyState is CONNECTED

  cacheable: require './cacheable'

  cacheableAsync: (rest...) ->
    new Promise (resolve, reject) =>
      @cacheable rest..., (err, model) ->
        return reject err  if err
        resolve model

  createRemoteApiShims:(api)->
    shimmedApi = {}
    for own name, {statik, instance, attributes} of api
      shimmedApi[name] = @createConstructor name, statik, instance, attributes
    shimmedApi

  guardMethod = (signatures, fn) -> (rest...) ->
    for signature in signatures when signature.test rest
      return fn.apply this, rest
    throw new Error "Unrecognized signature!"

  wrapStaticMethods:do ->
    optimizeThese = ['on','off']
    (constructor, constructorName, methods) ->
      bongo = this
      (Object.keys methods).forEach (method) ->
        signatures = methods[method].map Signature
        method += '_' if method in optimizeThese
        wrapper = guardMethod signatures, (rest...) ->
          rpc = {
            type: 'static'
            constructorName
            method
          }
          bongo.send rpc, rest
        wrapper.signatures = signatures
        constructor[method] = Bongo.promibackify wrapper

  wrapInstanceMethods:do ->
    optimizeThese = ['on','addListener','off','removeListener','save']
    (constructor, constructorName, methods) ->
      bongo = this
      (Object.keys methods).forEach (method) ->
        signatures = methods[method].map Signature
        method += '_' if method in optimizeThese
        wrapper = guardMethod signatures, (rest...) ->
          id = @getId()
          data = @data unless id?
          rpc = {
            type: 'instance'
            constructorName
            method
            id
            data
          }
          bongo.send rpc, rest
        wrapper.signatures = signatures
        constructor::[method] = Bongo.promibackify wrapper

  registerInstance:(inst)->
    inst.on 'listenerRemoved', (event, listener)=>
      @eventBus.off inst, event, listener.bind inst
    inst.on 'newListener', (event, listener)=>
      @eventBus.on inst, event, listener.bind inst

  getEventChannelName =(name)-> "event-#{name}"

  getRevivingListener =(bongo, ctx, listener)->
    (rest...)-> listener.apply ctx, bongo.revive rest

  addGlobalListener =(konstructor, event, listener)->
    @eventBus.staticOn konstructor, event, (rest...)=>
      revived = @revive rest
      listener.apply konstructor, revived

  reviveType:(type, shouldWrap)->
    return @reviveType type[0], yes   if Array.isArray type
    return type                       unless 'string' is typeof type
    revived = @api[type] ?
              window[type] ?
              @opaqueTypes[type] ?= new OpaqueType type
    if shouldWrap then [revived] else revived

  reviveSchema:do->
    {keys}      = Object
    {isArray}   = Array
    reviveSchemaRecursively = (bongo, schema)->
      (keys schema)
        .map (slot)->
          type = schema[slot]
          if (type and 'object' is typeof type) and not isArray type
            type = reviveSchemaRecursively bongo, type
          [slot, type]
        .reduce (acc, [slot, type])->
          acc[slot] = bongo.reviveType type
          acc
        , {}
    reviveSchema = (schema)->
      reviveSchemaRecursively this, schema

  createConstructor:(name, staticMethods, instanceMethods, attributes)->
    konstructor = Function('bongo', """
      return function #{name} () {
        bongo.registerInstance(this);
        this.init.apply(this, [].slice.call(arguments));
        this.bongo_.constructorName = '#{name}';
      }
      """) this
    EventEmitter konstructor
    @wrapStaticMethods konstructor, name, staticMethods
    konstructor extends Model
    konstructor::updateInstanceChannel = @updateInstanceChannel
    konstructor.on 'newListener', addGlobalListener.bind @, konstructor
    konstructor.attributes = attributes
    @wrapInstanceMethods konstructor, name, instanceMethods
    konstructor

  getInstancesById:->

  getInstanceMethods:-> ['changeLoggedInState','updateSessionToken']

  revive:(obj)->
    bongo = @
    hasEncoder = Encoder?.XSSEncode?
    new Traverse(obj).map (node)->
      if node?.bongo_?
        {constructorName, instanceId} = node.bongo_
        instance = bongo.getInstancesById instanceId
        return @update instance, yes if instance?
        konstructor = bongo.api[node.bongo_.constructorName]
        unless konstructor?
          @update node
        else
          @update new konstructor node
      else if hasEncoder and 'string' is typeof node
        @update Encoder.XSSEncode node
      else
        @update node

  reviveFromSnapshots:do ->
    # TODO: fix this properly, but it avoids clobbering the _events property
    snapshotReviver =(k, v)->
      return  if k is '_events'
      return v
    (instances, callback)->
      results = instances.map (instance)=>
        revivee = null
        try
          revivee = JSON.parse instance.snapshot, snapshotReviver if instance.snapshot?
        catch e
          console.warn "couldn't revive snapshot! #{instance._id}"
          revivee = null

        return null  unless revivee
        @revive revivee

      results = results.filter Boolean
      callback null, results

  handleRequest:(message)->
    if message?.method is 'defineApi' and not @api?
      @defineApi message.arguments[0]
    else if message?.method is 'handshakeDone'
      @handshakeDone()
    else
      {method, context} = message
      scrubber = new Scrubber @localStore
      unscrubbed = scrubber.unscrub message, (callbackId)=>
        unless @remoteStore.has(callbackId)
          @remoteStore.add callbackId, (args...)=>
            @send callbackId, args
        @remoteStore.get callbackId
      revived = @revive unscrubbed
      if method in @getInstanceMethods()
        @[method] revived...
      else unless isNaN +method
        callback = @localStore.get(method)
        callback?.apply null, revived
      else unless method is 'auth.authOk' # ok to ignore that one
        console.warn 'Unhandleable message; dropping it on the floor.'
        # console.trace()
        # console.log message
        # console.log method

  reconnectHelper:->
    @mq.ready =>
      @authenticateUser()
      @readyState = CONNECTED
      @emit 'ready'

  connectHelper:(callback)->
    @mq.once 'connected', =>
      @emit 'ready'
      callback?()

    @channelName = createBongoName @resourceName

    @channel = @mq.subscribe @channelName, {connectDirectly:yes}

    @channel.exchange = @resourceName
    @channel.setAuthenticationInfo
      serviceType : 'bongo'
      name        : @resourceName
      clientId    : @getSessionToken()

    @channel.off 'message', @bound 'handleRequest'
    @channel.on 'message', @bound 'handleRequest'

    @reconnectHelper()

    @channel.once 'broker.subscribed', =>
      # apply the middleware
      @stack.forEach (fn)=> fn.call @

    @channel.on 'broker.subscribed', =>
      @emit 'connected'

      if @disconnectedAt
        @emit 'reconnected', disconnectedFor: Date.now() - @disconnectedAt
        @disconnectedAt = null

      if @lastMessage
        @channel.publish @lastMessage
        @lastMessage = null


  connect:(callback)->
    throw new Error "no broker client"  unless @mq?

    switch @readyState
      when CONNECTED, CONNECTING then return "already connected"
      when DISCONNECTED
        @readyState = CONNECTING
        @mq.connect()
        if callback?
          @mq.on 'connected', =>
            @emit 'ready'
            callback null
      else
        @readyState = CONNECTING
        @connectHelper callback

    if @mq.autoReconnect
      @mq.once 'disconnected', => @mq.once 'connected', => @reconnectHelper()

  disconnect:(shouldReconnect, callback)->
    # @channel.close().off()  if @channel?

    throw new Error "no broker client"  unless @mq?

    if 'function' is typeof shouldReconnect
      callback = shouldReconnect
      shouldReconnect = no

    return "already disconnected"  if @readyState is NOTCONNECTED or @readyState is DISCONNECTED

    @mq.once 'disconnected', callback.bind this  if callback?
    @mq.disconnect shouldReconnect
    @readyState = DISCONNECTED

  messageFailed:(message)->
    console.log 'MESSAGE FAILED', message

  getTimeout:(message, clientTimeout=5000)->
    setTimeout @messageFailed.bind(this, message), clientTimeout

  ping:(callback)->
    @send 'ping', callback  if @readyState is CONNECTED and @useWebsockets

  send:(method, args)->
    args = [args] unless Array.isArray args

    if @mq? and not @channel
      throw new Error 'No channel!'

    scrubber = new Scrubber @localStore
    scrubber.scrub args, =>
      message = scrubber.toDnodeProtocol()
      message.method = method
      message.sessionToken = @getSessionToken()
      message.userArea = @getUserArea()
      @sendHelper message

  sendHelper: (message) ->
    if @useWebsockets
      messageString = JSON.stringify message
      if @channel.isOpen
        @channel.publish messageString
      else
        @lastMessage = messageString
        @connect()
    else if @apiEndpoint
      konstructor = @api[message.method.constructorName]
      if @batchRequests and not konstructor?.attributes.bypassBatch
        @enqueueMessage message
      else
        @sendXhr @apiEndpoint, 'POST', [message]

  setOutboundTimer: ->
    @outboundQueue = []
    @outboundTimer = setInterval =>
      if @outboundQueue.length
        @sendXhr @apiEndpoint, 'POST', @outboundQueue
      @outboundQueue.length = 0
    , BATCH_CHUNK_MS

  enqueueMessage: (message) ->
    @outboundQueue.push message

  sendXhr: (url, method, queue) ->
    xhr = new XMLHttpRequest
    xhr.open method, url
    xhr.setRequestHeader "Content-type", "application/json;charset=UTF-8"
    xhr.onreadystatechange = =>

      return  if xhr.readyState is 0   # 0: UNSENT
      return  if xhr.readyState isnt 4 # 4: DONE

      if xhr.status >= 400
        @emit 'error', new Error "XHR Error: #{ xhr.status }"

      return  if xhr.status not in [200, 304]

      requests = JSON.parse xhr.response

      @handleRequest request for request in requests when request
    messageString = JSON.stringify { @channelName, queue }
    xhr.send messageString

  authenticateUser:->
    clientId = @getSessionToken()
    @send 'authenticateUser', [clientId, @bound 'changeLoggedInState']

  handshakeDone:->
    return  if @readyState is CONNECTED
    @readyState = CONNECTED
    @emit 'ready'
    @authenticateUser()

  defineApi:(api)->
    if api?
      @api or= @createRemoteApiShims api
    @handshakeDone()

  changeLoggedInState:(state)->
    @emit 'loggedInStateChanged', state

  updateSessionToken:(token)->
    @emit 'sessionTokenChanged', token

  fetchChannel:(channelName, callback)->
    throw new Error "no broker client"  unless @mq?

    channel = @mq.subscribe channelName
    channel.once 'broker.subscribed', -> callback channel

  use:(fn)->
    @stack.push fn

  monitorPresence:(callbacks)-> @send 'monitorPresence', callbacks

  subscribe:(name, options={}, callback)->
    throw new Error "no broker client"  unless @mq?

    options.serviceType ?= 'application'
    channel = @mq.subscribe name, options
    options.name = name
    options.clientId = @getSessionToken()

    channel.setAuthenticationInfo options
    if callback? then channel.once 'broker.subscribed', -> callback channel
    return channel

  xhrHandshake: ->
    @send 'xhrHandshake', (api) =>
      if @api
      then @handshakeDone()
      else @defineApi api
