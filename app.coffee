xcorr = require './build/Release/xcorr'
request = require 'superagent'
require('superagent-cache')(request, {
	cacheServiceConfig: {},
	cacheModuleConfig: [
		{
			type: 'node-cache'
			defaultExpiration: 7200
		}
	]
})

Jimp = require 'jimp'
config = require './config.json'
getMac = require('getmac').getMac
_ = require 'lodash'

console.log('Starting up...')
getMac (err,myMacAddress) ->

	hubUrl = 'http://localhost:8080/'
	hubImagesUrl = hubUrl + 'images/'

	console.log('Registering...')
	request.get('http://ipinfo.io/json').end (err, loc) ->
		location = loc.body
		request.post(hubUrl + 'api/devices').send({resinId: process.env.RESIN_DEVICE_UUID, macAddress: myMacAddress, location}).end (err, res) ->
			if err
				console.log(err)
			else
				console.log(res.body)

	pubnub = require("pubnub")({
	    publish_key   : config.publish_key,
	    subscribe_key : config.subscribe_key,
	    uuid: myMacAddress
	})

	console.log('Subscribing...')
	pubnub.subscribe({
		channel: 'work',
		heartbeat: 10,
		state: {
			status: 'Idle'
			chunkId: null
		},
		message: (m) -> console.log("new work! " + m)
	})

	processWork = (work) ->
		console.log('Starting task.')
		startTime = Date.now()

		pubnub.state({
			channel: 'work'
			state: {
				status: 'Working'
				chunkId: work.chunkId
			}
		})
		pubnub.publish({
			channel: 'working'
			message: {
				device: myMacAddress
				progress: 0
			}
		})
		targetImage = work.targetImage
		results = []
		amountDone = 0
		whenDone = () ->
			console.log('Done!')
			console.log(results)
			theResult = _.max(results, 'value')
			theResult.device = myMacAddress
			theResult.elapsedTime = Date.now() - startTime

			pubnub.publish({
				channel: 'working'
				message: {
					device: myMacAddress
					progress: 100
				}
			})

			pubnub.state({
				channel: 'work'
				state: {
					status: 'Idle'
					chunkId: null
				}
			})

			pubnub.publish({
				channel: 'results'
				message: theResult
			})

		progress = 0
		onProgress = (amountDone, totalSize) ->
			percent = amountDone * 100 / totalSize
			if Math.floor(percent / 10) > Math.floor(progress / 10)
				pubnub.publish({
					channel: 'working'
					message: {
						device: myMacAddress
						progress: percent
					}
				})
				progress = percent

		correlate = (ind, img, image1) ->
			console.log('Correlating #' + (ind+1))
			image2URL = hubImagesUrl + img.original_img
			request.get(image2URL).end (req, res) ->
				image2Buffer = res.body
				new Jimp image2Buffer, (err, image2) ->
					console.log('Result for #' + (ind + 1))
					result = xcorr(image1.bitmap.data, image2.bitmap.data)
					console.log(result)
					results[ind] = {
						value: result
						name: img.personName
						imageId: img.id
						chunkId: work.chunkId
					}
					amountDone += 1
					onProgress(amountDone, work.workSize)
					if(amountDone == work.workSize)
						whenDone()

		console.log('Getting:')
		console.log(hubImagesUrl + work.targetImage.original_img)
		request.get(hubImagesUrl + work.targetImage.original_img).end (req, res) ->
			image1Buffer = res.body
			new Jimp image1Buffer, (err, image1) ->
				ind = 0
				_.each work.images, (img) ->
					correlate(ind, img, image1)
					ind += 1
					


	pubnub.subscribe({
		channel: myMacAddress
		message: processWork
	})

	warmCache = (images) ->
		_.each images, (img) ->
			request.get(hubImagesUrl + img.original_img).end (err, res) ->
				console.log("Got image " + img.original_img)

	pubnub.subscribe({
		channel: 'images'
		message: warmCache
	})

	console.log('Ready.')
