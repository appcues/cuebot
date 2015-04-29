RSVP = require 'rsvp'
_ = require 'underscore'
debug = require('debug')('cuebot:poll')

QUESTION_EXPIRY = 30*60*1000


module.exports = (robot) ->
  debug 'Poll script loaded'

  recipientsRe = /(?:@([^\s]+))/g
  questionRe = /\@[^\s]+\s(?=[^@]*$)(.*)/

  # Keep track of all the open questions.
  questionsByUser = {}

  # Ask your team a question.
  robot.respond /ask (.*)/i, (res) ->
    now = Date.now()
    msg = res.match[1]
    id = _.uniqueId 'question'
    user = res.envelope.user
    users = robot.adapter.client.users
    recipients = msg.match(recipientsRe)
    question = msg.match(questionRe)[1]

    debug "[#{id}] Question asked."

    # You must mention recipients.
    unless recipients?.length
      res.reply 'Who am I supposed to ask?'
      debug "[#{id}] Invalid: question lacked recipients."
      return

    # Questions should end with a question mark because grammar.
    unless /\?$/.test(question)
      res.reply "That doesn't sound like a question."
      debug "[#{id}] Invalid: question lacked a question mark."
      return

    # Support @everyone.
    if '@everyone' in recipients
      recipients = []
      _.each users, (u) ->
        unless u.deleted or u.is_bot or u.id in [user.id, 'USLACKBOT']
          recipients.push u.name

    # Message recipients individually.
    debug "[#{id}] Notifying #{recipients.length} recipients.", recipients
    for recipient in recipients
      username = recipient.replace(/^@/, '')
      # Create a promise so we track when this question is answered.
      # Leave it open for a maximum of 30 minutes.
      deferred = RSVP.defer()
      timers = []

      # 5 minute warning.
      timers.push setTimeout ->
          robot.messageRoom username, "Time is running out to answer, \"#{question}\" Whaddya say?"
        , QUESTION_EXPIRY - 5*60*1000

      # Expired.
      timers.push setTimeout ->
          deferred.reject(new Error('Question expired'))
        , QUESTION_EXPIRY

      # Clear the timers if successfully answered.
      deferred.promise.then ->
        _.each timers, (tid) -> clearTimeout tid

      # Notify creator when someone failed to respond in time.
      deferred.promise.catch ->
        robot.messageRoom user.name, "#{username} didn't respond to your question in time."

      # Always remove the question from the lineup.
      deferred.promise.finally ->
        questions = questionsByUser[username] ?= []
        questionsByUser[username] = _.filter questions, (q) -> q.id is id

      questionsByUser[username] ?= []
      questionsByUser[username].push {
        id: id
        question: question
        createdAt: now
        createdBy: user
        _promise: deferred
      }
      robot.messageRoom username, question

    res.reply "Just asked them. I'll keep you posted."

  # Track responses to a question.
  robot.respond /answer (.*)/i, (res) ->
    answer = res.match[1]
    user = res.envelope.user

    # Find a question to answer.
    questions = questionsByUser[user.name] ? []

    # Answer the last question asked of us.
    question = questions.pop()
    author = question.createdBy

    # No questions!
    unless question
      res.reply "You haven't been asked any questions recently."
      return

    res.reply "Great, I'll let #{author.real_name} know."
    robot.messageRoom author.name, "#{user.real_name} responded, \"#{answer}\""

    # Resolve the promise now that the question has been answered.
    question._promise.resolve()

    if questions.length
      lastQ = _.last questions
      res.reply "Ahem, you still have #{questions.length} left. The last one was, \"#{lastQ.question}\" How would you like to respond?"
