'use strict'

EventEmitter = require 'microemitter'

module.exports = class ModelLoader extends EventEmitter

  constructor:(konstructor, @_id) ->
    @konstructor = konstructor

  load_ =->
    @konstructor.one {@_id}, (err, model) =>
      @emit 'load', err, model

  load:(listener)->
    @once 'load', (rest...) =>
      @isLoading = no
      listener rest...

    unless @isLoading
      @isLoading = yes
      load_.call @
