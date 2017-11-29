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


debugLog = (name) ->
  if (isDebug)
    console.log.apply(console, [ 'atom-cursor-indent:' + name ].concat( [].slice.call(arguments, 1) ))
    
    
nextTick = () ->
  return new Promise((resolve) ->
    process.nextTick(resolve)
    return
  )


# Run async side-effects for the editor state changes.
# See https://github.com/atom/atom/issues/16267
runEditorSideEffectsAsync = (runSideEffects) ->
  return nextTick().then(() ->
    return runSideEffects()
  )


# For async side effects, we need to verify the editor is still being handled.
isHandlingEditor = (editor) ->
  return !!editorHandlers.find((handler) -> (handler.editor == editor))


isLineContainsSelection = (editor, lineInfo) ->
  return editor.getSelections().filter((selection) -> !selection.isEmpty()).some((selection) -> selection.intersectsScreenRow(lineInfo.start.screenPos.row))


shouldConsiderLine = (editor, lineInfo) ->
  # NOTE(@sompylasar): The last line of the document seems to always be `softWrapped`.
  return (!lineInfo.softWrapped)


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
  trailingWhitespaceBufferText = editor.getTextInBufferRange(trailingWhitespaceBufferRange)
  if (trailingWhitespaceBufferText != '')
    editor.setTextInBufferRange(trailingWhitespaceBufferRange, '', { undo: 'skip' })
    return true
  return


removeIndentWhitespace = (editor, lineInfo) ->
  if (!ALL_WHITESPACE_REGEXP.test(lineInfo.bufferText))
    return

  lineBufferRange = new Range(lineInfo.start.bufferPos, lineInfo.end.bufferPos)
  lineBufferText = lineInfo.bufferText
  if (lineBufferText != '')
    editor.setTextInBufferRange(lineBufferRange, '', { undo: 'skip' })
    return true
  return


# NOTE(@sompylasar): `setIndentationForBufferRow` doesn't pass the `undo: 'skip'` option to `buffer.setTextInRange`. https://github.com/atom/atom/blob/42509544b65472b7742c2ac34a2c88aa7e996617/src/text-editor.js#L3480
setIndentationForBufferRowWithoutUndo = (editor, bufferRow, newLevel) ->
  prevIndentString = editor.lineTextForBufferRow(bufferRow).match(/^\s*/)[0]
  nextIndentString = editor.buildIndentString(newLevel)
  if (nextIndentString != prevIndentString)
    debugLog('setIndentationForBufferRowWithoutUndo', editor.getTitle(), editor.getPath(), {
      prevIndentString: prevIndentString,
      nextIndentString: nextIndentString,
    })
    prevIndentBufferRange = [[bufferRow, 0], [bufferRow, prevIndentString.length]]
    editor.setTextInBufferRange(prevIndentBufferRange, nextIndentString, { undo: 'skip' })
    return true
  return


autoIndentLine = (editor, lineInfo, desiredColumn, cursor) ->
  if (!ALL_WHITESPACE_REGEXP.test(lineInfo.bufferText))
    return

  if (isLineContainsSelection(editor, lineInfo))
    return

  bufferRow = lineInfo.end.bufferPos.row

  currIndentLevel = editor.indentationForBufferRow(bufferRow)
  suggestedIndentLevel = editor.suggestedIndentForBufferRow(bufferRow)
  editorTabLength = editor.getTabLength()
  if (desiredColumn >= 0)
    suggestedIndentLevel = Math.floor(desiredColumn / editorTabLength)

  debugLog('autoIndentLine', editor.getTitle(), editor.getPath(), {
    bufferRow: bufferRow,
    desiredColumn: desiredColumn,
    currIndentLevel: currIndentLevel,
    editorTabLength: editorTabLength,
    suggestedIndentLevel: suggestedIndentLevel,
  })

  if (currIndentLevel < suggestedIndentLevel)
    debugLog('autoIndentLine', editor.getTitle(), editor.getPath(), 'currIndentLevel < suggestedIndentLevel, setIndentationForBufferRowWithoutUndo()')
    hasChanged = setIndentationForBufferRowWithoutUndo(editor, bufferRow, suggestedIndentLevel)
    if (hasChanged && cursor)
      debugLog('autoIndentLine', editor.getTitle(), editor.getPath(), 'hasChanged, cursor.moveToEndOfScreenLine()')
      cursor.moveToEndOfLine()
    return hasChanged

  return


handleAddCursor = (editor, cursor) ->
  debugLog('handleAddCursor', editor.getTitle(), editor.getPath(), {
  })

  runEditorSideEffectsForAddCursor = () ->
    if (!isHandlingEditor(editor))
      return

    screenRow = cursor.getScreenRow()

    lineInfo = getLineInfo(editor, screenRow)
    lineShouldConsider = shouldConsiderLine(editor, lineInfo)
    if (!lineShouldConsider)
      return

    cursorsOnTheSameLineLength = editor.getCursors().filter((c) -> (c != cursor && c.getScreenRow() == screenRow)).length

    debugLog('handleAddCursor:runEditorSideEffectsForAddCursor', editor.getTitle(), editor.getPath(), {
      screenRow: screenRow,
      lineInfo: lineInfo,
      lineShouldConsider: lineShouldConsider,
      cursorsOnTheSameLineLength: cursorsOnTheSameLineLength,
    })

    if (cursorsOnTheSameLineLength <= 0)
      autoIndentLine(editor, lineInfo)

    return

  return runEditorSideEffectsAsync(runEditorSideEffectsForAddCursor)


handleRemoveCursor = (editor, cursor) ->
  screenRow = cursor.marker.oldTailScreenPosition.row

  debugLog('handleRemoveCursor', editor.getTitle(), editor.getPath(), {
    screenRow: screenRow,
  })

  runEditorSideEffectsForRemoveCursor = () ->
    if (!isHandlingEditor(editor))
      return

    lineInfo = getLineInfo(editor, screenRow)
    lineShouldConsider = shouldConsiderLine(editor, lineInfo)
    if (!lineShouldConsider)
      return

    cursorsOnTheSameLine = editor.getCursors().filter((c) -> (c != cursor && c.getScreenRow() == screenRow))

    rightmostCursorOnTheSameLineScreenColumn = -1
    if (cursorsOnTheSameLine.length > 0)
      cursorsOnTheSameLine.sort((left, right) -> (left.getScreenPosition().column - right.getScreenPosition().column))
      rightmostCursorOnTheSameLine = cursorsOnTheSameLine[cursorsOnTheSameLine.length - 1]
      rightmostCursorOnTheSameLineScreenColumn = rightmostCursorOnTheSameLine.getScreenPosition().column

    debugLog('handleRemoveCursor:runEditorSideEffectsForRemoveCursor', editor.getTitle(), editor.getPath(), {
      screenRow: screenRow,
      lineInfo: lineInfo,
      lineShouldConsider: lineShouldConsider,
      rightmostCursorOnTheSameLineScreenColumn: rightmostCursorOnTheSameLineScreenColumn,
    })

    if (rightmostCursorOnTheSameLineScreenColumn >= 0)
      removeTrailingWhitespace(editor, lineInfo, rightmostCursorOnTheSameLineScreenColumn)
    else
      removeIndentWhitespace(editor, lineInfo)
      removeTrailingWhitespace(editor, lineInfo)

    return

  return runEditorSideEffectsAsync(runEditorSideEffectsForRemoveCursor)


handleChangeCursorPosition = (editor, event) ->
  if (event.textChanged)
    return

  cursor = event.cursor
  prevScreenRow = event.oldScreenPosition.row
  prevScreenColumn = event.oldScreenPosition.column

  debugLog('handleChangeCursorPosition', editor.getTitle(), editor.getPath(), {
    prevScreenRow: prevScreenRow,
    prevScreenColumn: prevScreenColumn,
  })

  runEditorSideEffectsForChangeCursorPosition = () ->
    if (!isHandlingEditor(editor))
      return

    nextScreenRow = cursor.getScreenRow()
    nextScreenColumn = cursor.getScreenColumn()

    backspacedToColumn = -1
    if (nextScreenRow == prevScreenRow && nextScreenColumn < prevScreenColumn)
      backspacedToColumn = nextScreenColumn

    prevLineInfo = getLineInfo(editor, prevScreenRow)
    nextLineInfo = getLineInfo(editor, nextScreenRow)

    prevLineShouldConsider = shouldConsiderLine(editor, prevLineInfo)
    nextLineShouldConsider = shouldConsiderLine(editor, nextLineInfo)

    debugLog('handleChangeCursorPosition:runEditorSideEffectsForChangeCursorPosition', editor.getTitle(), editor.getPath(), {
      prevScreenRow: prevScreenRow,
      prevScreenColumn: prevScreenColumn,
      nextScreenRow: nextScreenRow,
      nextScreenColumn: nextScreenColumn,
      backspacedToColumn: backspacedToColumn,
      prevLineInfo: prevLineInfo,
      nextLineInfo: nextLineInfo,
      prevLineShouldConsider: prevLineShouldConsider,
      nextLineShouldConsider: nextLineShouldConsider,
    })

    if (prevLineShouldConsider && (nextScreenRow != prevScreenRow || !nextLineShouldConsider))
      removeIndentWhitespace(editor, prevLineInfo)
      removeTrailingWhitespace(editor, prevLineInfo)

    if (nextLineShouldConsider)
      autoIndentLine(editor, nextLineInfo, backspacedToColumn, cursor)

    return

  return runEditorSideEffectsAsync(runEditorSideEffectsForChangeCursorPosition)


cleanupBeforeSave = (editor) ->
  debugLog('cleanupBeforeSave', editor.getTitle(), editor.getPath())

  # Remove the indentation before saving as if the cursors were removed.
  return Promise.all(editor.getCursors().map((cursor) -> handleRemoveCursor(editor, cursor)))


ensurePromiseAndErrorHandling = (name, func) ->
  return Promise.resolve().then(() -> func()).catch((error) ->
    console.error('atom-cursor-indent:' + name, editor.getTitle(), editor.getPath(), error)
    return
  ).catch(() -> Promise.resolve())


createEditorHandler = (editor, params) ->
  subscriptionsForEditor = new CompositeDisposable()
  handling = false

  handler = {
    editor: editor,
    dispose: () ->
      params.onWillDispose(handler)
      subscriptionsForEditor.dispose()
      return
  }

  onDidAddCursor = (cursor) ->
    ensurePromiseAndErrorHandling('onDidAddCursor', () -> handleAddCursor(editor, cursor))
    return

  onDidRemoveCursor = (cursor) ->
    ensurePromiseAndErrorHandling('onDidRemoveCursor', () -> handleRemoveCursor(editor, cursor))
    return

  onDidChangeCursorPosition = (event) ->
    ensurePromiseAndErrorHandling('onDidChangeCursorPosition', () -> handleChangeCursorPosition(editor, event))
    return

  onWillSave = () ->
    return ensurePromiseAndErrorHandling('onWillSave', () -> cleanupBeforeSave(editor))

  onDidDestroy = () ->
    handler.dispose()
    return

  subscriptionsForEditor.add(editor.onDidDestroy(onDidDestroy))
  subscriptionsForEditor.add(editor.getBuffer().onWillSave(onWillSave))
  subscriptionsForEditor.add(editor.onDidAddCursor(onDidAddCursor))
  subscriptionsForEditor.add(editor.onDidRemoveCursor(onDidRemoveCursor))
  subscriptionsForEditor.add(editor.onDidChangeCursorPosition(onDidChangeCursorPosition))
  return handler


onEditorHandlerWillDispose = (handler) ->
  debugLog('onEditorHandlerWillDispose', handler.editor.getTitle(), handler.editor.getPath())

  editorHandlers.splice(editorHandlers.indexOf(handler), 1)
  return


onNewEditor = (editor) ->
  debugLog('onNewEditor', editor.getTitle(), editor.getPath())

  editorHandlers.push(createEditorHandler(editor, {
    onWillDispose: onEditorHandlerWillDispose
  }))
  return


# exports
module.exports.activate = () ->
  debugLog('activate')

  subscriptions.add(atom.workspace.observeTextEditors(onNewEditor))
  return


module.exports.deactivate = () ->
  debugLog('deactivate')

  subscriptions.dispose()
  editorHandlers.forEach((handler) -> handler.dispose())
  return
