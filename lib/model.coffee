'use strict'

Encoder      = require 'htmlencode'
EventEmitter = require 'microemitter'
{extend}     = require './util'
Traverse     = require 'traverse'
MongoOp      = require 'mongoop'
JsPath       = require 'jspath'
xssEncode    = (data) ->
  return new Traverse(data).map (node) ->
    return Encoder.XSSEncode node  if 'string' is typeof node
    return node


module.exports = class Model extends EventEmitter

  createId  = @createId = require 'hat'
  @isOpaque = -> no

  @streamModels =(selector, options, callback)->
    unless 'each' of this then throw new Error """
      streamModels depends on Model#each, but cursor was not found!
      (Hint: it may not be whitelisted)
      """
    ids = []
    @each selector, options, (err, model)->
      if err then callback err
      else if model?
        ids.push model.getId?()
        callback err, [model]
      else
        callback null, null, ids

  mixin: @mixin = (source)->
    @[key] = val for key,val of source when key isnt 'constructor'

  watch:(field, watcher)->
    @watchers[field] or= []
    @watchers[field].push watcher

  unwatch:(field, watcher)->
    unless watcher
      delete @watchers[field]
    else
      index = @watchers.indexOf watcher
      @watchers.splice index, 1  if ~index

  init: (data) ->
    model           = this
    model.watchers  = {}
    model.bongo_  or= {}

    if data?
      model.set data
    unless 'instanceId' of model.bongo_
      model.bongo_.instanceId = createId()

    @emit 'init'
    @on 'updateInstance', (data) =>
      @update_ xssEncode data

  set:(data={})->
    model = this
    delete data.data
    extend model, xssEncode data
    model

  getFlagValue:(flagName)->
    @flags_?[flagName]

  watchFlagValue:(flagName, callback)->
    @watch "flags_.#{flagName}", callback

  unwatchFlagValue:(flagName)->
    @unwatch "flags_.#{flagName}"

  decoded:
    if `Encoder`?
    then (path)-> `Encoder`.htmlDecode @getAt path
    else  @::getAt

  getAt:(path)-> JsPath.getAt @, path

  setAt:(path, value)->
    JsPath.setAt @, path, value
    @emit 'update', [path]

  getId:-> @_id

  getToken: -> @token or @getId()

  getSubscribable:->
    {subscribable} = @bongo_
    return subscribable  if subscribable?
    return true

  equals:(model)->
    if @getId and model?.getId
      @getId() is model.getId()
    else
      @ is model

  valueOf: -> @getValue?() ? this # magical valueOf kludge

  save:(callback)->
    model = @
    model.save_ (err, docs)->
      if err
        callback err
      else
        extend model, docs[0] # replace local values with server-validated ones.
        bongo.addReferences model
        callback null, docs

  # emit:(event, rest...)->
  #   listeners = @multiplexer.events[event]?.listeners || []
  #   listener.apply @, rest for listener in listeners

  update_:(data)->
    fields = new MongoOp(data).applyTo @
    Object.keys(fields).forEach (field)=>
      @watchers[field]?.forEach (watcher)=> watcher.call @, fields[field]
    @emit 'update', (Object.keys fields.result)
  # alias these:
  addListener     : @::on
  removeListener  : @::off
