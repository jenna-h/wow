'use strict'

# Import a bunch of stuff. This isn't really getting used right now, but hey. Maybe someday.
import { reactiveLocalStorage } from './imports/storage.coffee'

# Import all the stuff we need to use markdown
import sanitizeHtml from 'sanitize-html';
import { createMarkdown } from 'safe-marked'
markdown = createMarkdown()
defaultMd = 'Welcome to Simhunt!'

# Import time library
import TimeAgo from 'javascript-time-ago'
import en from 'javascript-time-ago/locale/en.json'
TimeAgo.addDefaultLocale(en)
timeAgo = new TimeAgo('en-US')

model = share.model # import
settings = share.settings # import

# --- Whiteboard ---
isWhiteboardEditing = ReactiveVar(false);
whiteboardEditing = -> isWhiteboardEditing.get()

# Helper function to escape and sanitize all HTML
sanitizeAllHtml = (content) ->
  sanitizeHtml(content, 
      { allowedTags: [], allowedAttributes: {}, disallowedTagsMode: 'recursiveEscape' }).trim()

# Simple getter methods
whiteboardMd = ->
  whiteboard = model.Whiteboard.findOne({}, { sort: { timestamp: -1 } })
  content = if whiteboard? then (whiteboard.content or defaultMd) else defaultMd
  return sanitizeAllHtml(content).trim()
whiteboardHtml = ->
  markdown(whiteboardMd())

# Time display
timeDisplay = ReactiveVar()
updateTimeDisplay = -> 
  whiteboard = model.Whiteboard.findOne({}, { sort: { timestamp: -1 } })
  if whiteboard? 
    timeDisplay.set('Last updated ' + timeAgo.format(whiteboard.timestamp))
  else
    timeDisplay.set('Never updated')
whiteboardTimeDisplay = ->
  timeDisplay.get()
  

# Setter method
whiteboardSubmit = (content) ->
  Meteor.call 'whiteboardSubmit', sanitizeAllHtml(content)

# --- Puzzles for You ---
allhands_tag = 'all hands (swarm)'

# Given a map and key, returns map[key] if it is defined and 0 otherwise.
getDefaultZero = (map, key) ->
  if map[key]?
    return map[key]
  return 0

# Gets puzzles with one of this user's favorite mechanics, besides allhands. 
# Modified from blackboard.coffee.
favorites = ->
  query = $or: [
    {"favorites.#{Meteor.userId()}": true},
    mechanics: $in: Meteor.user().favorite_mechanics.filter((m) -> m != allhands_tag) or []
  ]
  if not Session.get('canEdit') and 'true' is reactiveLocalStorage.getItem 'hideSolved'
    query.solved = $eq: null
  model.Puzzles.find query

# Gets puzzles with the allhands tag.
allhands_puzzles = ->
  query = {mechanics: allhands_tag}
  if not Session.get('canEdit') and 'true' is reactiveLocalStorage.getItem 'hideSolved'
    query.solved = $eq: null
  model.Puzzles.find query

# Does this user have allhands enabled?
is_subscribed_allhands = ->
  allhands_tag in Meteor.user().favorite_mechanics

# Keep track of how many times someone hit 'later' on a puzzle.
# This needs to be a ReactiveVar so that the sidebar updates when the user clicks 'later'.
# 
# Note that this variable is defined anew every time someone refreshes the page.
# We don't really expect that people will refresh the page that often (maybe they walked away and came back), 
# so having the # passes tracker reset every once in a while is probably good.
id_to_num_passes = new ReactiveVar({})

# Gets a list of suggested puzzles for this user, based on the current status of the hunt and their preferences.
# 
# Currently, the list of suggested puzzles consists of:
#  - "Close metas" (where close is defined by `close_meta_thresh` in the code below) and their feeders
#  - Stuck puzzles
#      ~ Unsolved metas
#      ~ Feeders to unsolved metas
#      ~ Unassigned puzzles
#  - Puzzles that use favorite mechanics
# 
# After the above ordering is applied, the puzzles are sorted based on the number of times the user "passed on" them
# (hit 'later'). Puzzles that were passed on fewer times will be at the top.
#
# Then, the first few of puzzles (as defined by `num_to_show`) are extracted and returned.
#
# The 'puzzle' objects that this method returns are the same as the Puzzle model from model.coffee, but they have
# an additional field, called 'reasons', of type Array<string>. Each one of the string elements is a descriptor
# of why this puzzle is suggested right now.
suggestions = ->
  # Map puzzle IDs to data objects. Each data object is the same as the Puzzle model from model.coffee,
  # but it has an additional 'reasons' field.
  ids_to_data = {}

  # A helper function that adds a reason to the reasons field of the data object in ids_to_data.
  addReason = (puzzleList, reason) ->
    puzzleList.forEach((puzzle) ->
      if ids_to_data[puzzle._id]?
        ids_to_data[puzzle._id].reasons.push(reason)
      else
        ids_to_data[puzzle._id] = Object.assign({reasons: [reason]}, puzzle)
    )

  # Get a list of unsolved metas. This will be helpful later.
  unsolved_metas = []
  model.Rounds.find({solved: null}, sort: [["sort_key", 'asc']]).forEach((round) -> 
    unsolved_metas.push(...round.puzzles
      .map((id) -> model.Puzzles.findOne({_id: id, puzzles: {$ne: null}, solved: null}))
      .filter((meta) -> meta?) # Take out all the "undefined"
    )
  )

  # Get puzzles with the 'all hands' tag.
  allhands_message = 'Calling all teammates to work on this puzzle together!'
  if is_subscribed_allhands
    addReason(allhands_puzzles(), allhands_message)

  # Get "close metas" and their feeders.
  close_meta_thresh = 3
  close_meta_message = 'This meta is unsolved, but almost all its feeders are solved.'
  unsolved_in_close_meta_message = 'This puzzle belongs to an unsolved meta that needs only a few more feeder solves.'

  close_metas = unsolved_metas
      .filter((meta) -> meta.puzzles.reduce(((acc, cur) -> if cur.solved is null then acc + 1 else acc), 0) >= meta.puzzles.length - close_meta_thresh)
      .map((meta) -> Object.assign({reasons: [close_meta_message]}, meta))
  addReason(close_metas, close_meta_message)
  
  unsolved_puzzles_in_close_metas = close_metas
    .flatMap((meta) -> meta.puzzles).map((id) -> model.Puzzles.findOne({_id: id, solved: null})).filter((puzzle) -> puzzle?)
  addReason(unsolved_puzzles_in_close_metas, unsolved_in_close_meta_message)

  # Get stuck puzzles that are unsolved metas or that belong to unsolved metas.
  stuck_unsolved_meta_message = 'This meta is unsolved and it has been marked STUCK.'
  stuck_in_unsolved_meta_message = 'This puzzle belongs to an unsolved meta and it has been marked STUCK.'

  stuck_metas = unsolved_metas.filter((meta) -> share.model.isStuck meta)
  addReason(stuck_metas, stuck_unsolved_meta_message)

  stuck_puzzles_in_unsolved_metas = unsolved_metas
    .flatMap((meta) -> meta.puzzles).map((id) -> model.Puzzles.findOne({_id: id, solved: null})).filter((puzzle) -> puzzle?)
    .filter((puzzle) -> share.model.isStuck puzzle)
  addReason(stuck_puzzles_in_unsolved_metas, stuck_in_unsolved_meta_message)

  # Get stuck puzzles that are unassigned.
  stuck_unassigned_message = 'This puzzle has been marked STUCK.'

  stuck_unassigned = []
  model.Rounds.find({solved: null}, sort: [["sort_key", 'asc']]).forEach((round) -> 
    stuck_unassigned.push(...round.puzzles
      .map((id) -> model.Puzzles.findOne({_id: id, feedsInto: {$size: 0}, puzzles: {$exists: false}}))
      .filter((puzzle) -> puzzle?) # Take out all the "undefined"
      .filter((puzzle) -> share.model.isStuck puzzle)
    )
  )
  addReason(stuck_unassigned, stuck_unassigned_message)

  # Get favorite mechanics.
  fave_message = 'This puzzle uses one of your favorite mechanics.'
  addReason(favorites(), fave_message)

  # Now get all the suggestions and sort them by number of passes (fewer passes go on top).
  all_suggestions = (data for own id, data of ids_to_data)
  all_suggestions.sort((a, b) -> 
    return getDefaultZero(id_to_num_passes.get(), a._id) - getDefaultZero(id_to_num_passes.get(), b._id)
  )

  # Clip the results.
  num_to_show = 3
  return all_suggestions.slice(0, num_to_show)

# -- Entire-sidebar template functions --
Template.bulletin_sidebar.helpers
  suggestions: suggestions # The overall sidebar needs to know what the suggestions are.

# -- Whiteboard-specific template functions --
Template.whiteboard.onCreated -> this.autorun =>
  this.subscribe 'whiteboard'
  updateTimeDisplay() # Initialize timer
  Meteor.setInterval(updateTimeDisplay, 1*60*1000) # Update timer every 1 minute

Template.whiteboard.helpers
  whiteboardEditing: whiteboardEditing
  whiteboardHtml: whiteboardHtml
  whiteboardMd: whiteboardMd
  whiteboardTimeDisplay: whiteboardTimeDisplay

Template.whiteboard.events
  'click .whiteboard-content': (event, template) ->
    isWhiteboardEditing.set(true)

  'blur textarea': (event, template) ->
    value = document.getElementById('whiteboard-textbox').value
    whiteboardSubmit(value)
    isWhiteboardEditing.set(false)

# Needed to adjust height on textbox
Template.whiteboard_textbox.onRendered ->
  textbox = document.getElementById('whiteboard-textbox')
  if textbox? 
    textbox.style.height = textbox.scrollHeight + 'px'


# -- Puzzle-suggestion-specific template functions --

# Manage clicks on the 'later' buttons.
Template.bulletin_puzzle.events
    'click .bb-later': (event, template) -> 
      targetPuzzleId = $(event.currentTarget).attr('data-id')

      # Get the current map of id to # passes
      currentIdMap = id_to_num_passes.get()

      # Then increment the # passes for the target puzzle ID
      currNumPasses = getDefaultZero(currentIdMap, targetPuzzleId)
      currentIdMap[targetPuzzleId] = currNumPasses + 1

      # "Reassign" the value of the ReactiveVar, `id_to_num_passes`.
      # This must be done to ensure re-sorting of the sidebar (which is just re-rendering).
      id_to_num_passes.set(currentIdMap)