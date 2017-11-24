# coffeelint: disable=max_line_length

{ Point, Range, CompositeDisposable } = require 'atom'

# settings
# TODO(@sompylasar): Read the settings from configuration.
grammarScopesToKeepTrailingWhitespace = [ 'source.gfm' ]

# globals
subscriptions = new CompositeDisposable()
editorHandlers = []
isDebug = atom.inDevMode()
ALL_WHITESPACE_REGEXP = /^\s*$/


getLineInfo = (editor, screenRow) ->
  screenText = (editor.lineTextForScreenRow(screenRow) || '')
  startScreenPos = new Point(screenRow, 0)
  startBufferPos = editor.bufferPositionForScreenPosition(startScreenPos)
  endScreenPos = new Point(screenRow, screenText.length)
  endBufferPos = editor.bufferPositionForScreenPosition(endScreenPos)
  bufferRange = new Range(startBufferPos, endBufferPos)
  bufferText = editor.getTextInBufferRange(bufferRange)
  nextBufferRow = editor.bufferRowForScreenRow(screenRow + 1)
  return {
    screenText,
    bufferText,
    bufferRange,
    softWrapped: (nextBufferRow <= endBufferPos.row),
    start: {
      screenPos: startScreenPos,
      bufferPos: startBufferPos,
    },
    end: {
      screenPos: endScreenPos,
      bufferPos: endBufferPos,
    },
  }


removeTrailingWhitespace = (editor, lineInfo, keepColumn = 0) ->
  if (ALL_WHITESPACE_REGEXP.test(lineInfo.bufferText))
    return

  scopeDescriptor = editor.scopeDescriptorForBufferPosition(lineInfo.end.bufferPos)
  sourceScopeNames = scopeDescriptor.getScopesArray().filter((scopeName) -> (/^source\./.test(scopeName)))

  shouldKeepTrailingWhitespace = (
    sourceScopeNames.length <= 0 ||
    grammarScopesToKeepTrailingWhitespace.indexOf(sourceScopeNames[sourceScopeNames.length - 1]) >= 0
  )

  if (shouldKeepTrailingWhitespace)
    return

  trailingWhitespaceLength = lineInfo.bufferText.length - lineInfo.bufferText.replace(/\s+$/, '').length
  currLineEndNoWhitespaceBufferPos = new Point(lineInfo.end.bufferPos.row, Math.max(keepColumn, lineInfo.end.bufferPos.column - trailingWhitespaceLength))
  trailingWhitespaceBufferRange = new Range(currLineEndNoWhitespaceBufferPos, lineInfo.end.bufferPos)
  editor.setTextInBufferRange(trailingWhitespaceBufferRange, '', { undo: 'skip' })
  return


removeIndentWhitespace = (editor, lineInfo) ->
  if (!ALL_WHITESPACE_REGEXP.test(lineInfo.bufferText))
    return

  bufferRange = new Range(lineInfo.start.bufferPos, lineInfo.end.bufferPos)
  editor.setTextInBufferRange(bufferRange, '', { undo: 'skip' })
  return


# NOTE(@sompylasar): `setIndentationForBufferRow` doesn't pass the `undo: 'skip'` option to `buffer.setTextInRange`. https://github.com/atom/atom/blob/42509544b65472b7742c2ac34a2c88aa7e996617/src/text-editor.js#L3480
setIndentationForBufferRowWithoutUndo = (editor, bufferRow, newLevel) ->
  endColumn = editor.lineTextForBufferRow(bufferRow).match(/^\s*/)[0].length
  newIndentString = editor.buildIndentString(newLevel)
  editor.setTextInBufferRange([[bufferRow, 0], [bufferRow, endColumn]], newIndentString, { undo: 'skip' })
  return true


autoIndentLine = (editor, lineInfo, desiredColumn) ->
  if (!ALL_WHITESPACE_REGEXP.test(lineInfo.bufferText))
    return

  bufferRow = lineInfo.end.bufferPos.row
  screenRow = lineInfo.end.screenPos.row
  currIndentLevel = editor.indentationForBufferRow(bufferRow)
  suggestedIndentLevel = editor.suggestedIndentForBufferRow(bufferRow)
  if (desiredColumn >= 0)
    suggestedIndentLevel = Math.floor(desiredColumn / editor.getTabLength())

  if (isDebug)
    console.log('atom-cursor-indent:autoIndentLine', editor.getTitle(), editor.getPath(), 'desiredColumn ==', desiredColumn, 'currIndentLevel ==', currIndentLevel, 'suggestedIndentLevel ==', suggestedIndentLevel)

  if (currIndentLevel < suggestedIndentLevel)
    return setIndentationForBufferRowWithoutUndo(editor, bufferRow, suggestedIndentLevel)

  return


shouldConsiderLine = (editor, lineInfo) ->
  # NOTE(@sompylasar): The last line of the document seems to always be `softWrapped`.
  return (!lineInfo.softWrapped)


handleAddCursor = (editor, cursor) ->
  screenRow = cursor.getScreenRow()
  lineInfo = getLineInfo(editor, screenRow)

  if (isDebug)
    console.log('atom-cursor-indent:handleAddCursor', editor.getTitle(), editor.getPath(), 'screenRow ==', screenRow)

  if (shouldConsiderLine(editor, lineInfo))
    cursorsOnTheSameLine = editor.getCursors().filter((c) -> (c != cursor && c.getScreenRow() == screenRow))
    if (cursorsOnTheSameLine.length <= 0 && autoIndentLine(editor, lineInfo))
      cursor.moveToEndOfScreenLine()

  return


handleRemoveCursor = (editor, cursor) ->
  screenRow = cursor.marker.oldTailScreenPosition.row
  lineInfo = getLineInfo(editor, screenRow)

  if (isDebug)
    console.log('atom-cursor-indent:handleRemoveCursor', editor.getTitle(), editor.getPath(), 'screenRow ==', screenRow)

  if (shouldConsiderLine(editor, lineInfo))
    cursorsOnTheSameLine = editor.getCursors().filter((c) -> (c != cursor && c.getScreenRow() == screenRow))
    if (cursorsOnTheSameLine.length > 0)
      cursorsOnTheSameLine.sort((left, right) -> (left.getScreenPosition().column - right.getScreenPosition().column))
      rightmostCursor = cursorsOnTheSameLine[cursorsOnTheSameLine.length - 1]
      removeTrailingWhitespace(editor, lineInfo, rightmostCursor.getScreenPosition().column)
    else
      removeIndentWhitespace(editor, lineInfo)
      removeTrailingWhitespace(editor, lineInfo)

  return


handleChangeCursorPosition = (editor, event) ->
  if (event.textChanged)
    return

  cursor = event.cursor
  prevScreenRow = event.oldScreenPosition.row
  nextScreenRow = event.newScreenPosition.row

  backspacedToColumn = -1
  if (nextScreenRow == prevScreenRow && event.newScreenPosition.column < event.oldScreenPosition.column)
    backspacedToColumn = event.newScreenPosition.column

  prevLineInfo = getLineInfo(editor, prevScreenRow)
  nextLineInfo = getLineInfo(editor, nextScreenRow)

  if (isDebug)
    console.log('atom-cursor-indent:handleChangeCursorPosition', editor.getTitle(), editor.getPath(), 'prevScreenRow ==', prevScreenRow, 'nextScreenRow ==', nextScreenRow)

  if (shouldConsiderLine(editor, prevLineInfo))
    removeIndentWhitespace(editor, prevLineInfo)
    removeTrailingWhitespace(editor, prevLineInfo)

  if (shouldConsiderLine(editor, nextLineInfo))
    if (autoIndentLine(editor, nextLineInfo, backspacedToColumn))
      cursor.moveToEndOfScreenLine()

  return


cleanupBeforeSave = (editor) ->
  if (isDebug)
    console.log('atom-cursor-indent:cleanupBeforeSave', editor.getTitle(), editor.getPath())

  # Remove the indentation before saving.
  editor.getCursors().forEach((cursor) -> handleRemoveCursor(editor, cursor))
  return


createEditorHandler = (editor, params) ->
  subscriptionsForEditor = new CompositeDisposable()
  handling = false

  handler = {
    editor: editor,
    dispose: () ->
      subscriptionsForEditor.dispose()
      params.onDispose(handler)
      return
  }

  onDidAddCursor = (cursor) ->
    handleAddCursor(editor, cursor)
    return

  onDidRemoveCursor = (cursor) ->
    handleRemoveCursor(editor, cursor)
    return

  onDidChangeCursorPosition = (event) ->
    # Prevent recursion.
    if (handling)
      return
    handling = true
    try
      handleChangeCursorPosition(editor, event)
    finally
      handling = false
    return

  onWillSave = () ->
    # Prevent recursion.
    if (handling)
      return
    handling = true
    try
      cleanupBeforeSave(editor)
    catch ex
      # NOTE(@sompylasar): Catch here to proceed with saving regardless of a potential exception.
      console.error('atom-cursor-indent:onWillSave', editor.getTitle(), editor.getPath(), ex)
    finally
      handling = false
    return

  onDidDestroy = () ->
    handler.dispose()
    return

  subscriptionsForEditor.add(editor.onDidDestroy(onDidDestroy))
  subscriptionsForEditor.add(editor.getBuffer().onWillSave(onWillSave))
  subscriptionsForEditor.add(editor.onDidAddCursor(onDidAddCursor))
  subscriptionsForEditor.add(editor.onDidRemoveCursor(onDidRemoveCursor))
  subscriptionsForEditor.add(editor.onDidChangeCursorPosition(onDidChangeCursorPosition))
  return handler


onEditorHandlerDispose = (handler) ->
  if (isDebug)
    console.log('atom-cursor-indent:onEditorHandlerDispose', handler.editor.getTitle(), handler.editor.getPath())

  editorHandlers.splice(editorHandlers.indexOf(handler), 1)
  return


onNewEditor = (editor) ->
  if (isDebug)
    console.log('atom-cursor-indent:onNewEditor', editor.getTitle(), editor.getPath())

  editorHandlers.push(createEditorHandler(editor, {
    onDispose: onEditorHandlerDispose
  }))
  return


# exports
module.exports.activate = () ->
  if (isDebug)
    console.log('atom-cursor-indent:activate')

  subscriptions.add(atom.workspace.observeTextEditors(onNewEditor))
  return


module.exports.deactivate = () ->
  if (isDebug)
    console.log('atom-cursor-indent:deactivate')

  subscriptions.dispose()
  editorHandlers.forEach((handler) -> handler.dispose())
  return
