{ Point, Range } = require 'atom'

ALL_WHITESPACE_REGEXP = /^\s*$/

getLineInfo = (editor, screenRow) ->
  screenText = (editor.lineTextForScreenRow(screenRow) || '')
  startScreenPos = new Point(screenRow, 0)
  startBufferPos = editor.bufferPositionForScreenPosition(startScreenPos)
  endScreenPos = new Point(screenRow, screenText.length)
  endBufferPos = editor.bufferPositionForScreenPosition(endScreenPos)
  bufferRange = new Range(startBufferPos, endBufferPos)
  bufferText = editor.getTextInBufferRange(bufferRange)
  return {
    screenText,
    bufferText,
    bufferRange,
    start: {
      screenPos: startScreenPos,
      bufferPos: startBufferPos,
    },
    end: {
      screenPos: endScreenPos,
      bufferPos: endBufferPos,
    },
  }

removeTrailingWhitespace = (editor, lineInfo) ->
  trailingWhitespaceLength = lineInfo.bufferText.length - lineInfo.bufferText.replace(/\s+$/, '').length
  currLineEndNoWhitespaceBufferPos = new Point(lineInfo.end.bufferPos.row, lineInfo.end.bufferPos.column - trailingWhitespaceLength)
  trailingWhitespaceBufferRange = new Range(currLineEndNoWhitespaceBufferPos, lineInfo.end.bufferPos)
  editor.setTextInBufferRange(trailingWhitespaceBufferRange, '')
  
autoIndentLine = (editor, lineInfo) ->
  backupSelectedBufferRanges = editor.getSelectedBufferRanges()
  editor.setSelectedBufferRange(new Range(lineInfo.start.bufferPos, lineInfo.end.bufferPos))
  editor.autoIndentSelectedRows()
  editor.setSelectedBufferRanges(backupSelectedBufferRanges)

handleChangeCursorPosition = (editor, event) ->
  if event.textChanged
    return

  if !editor.getLastSelection().isEmpty()
    return

  currScreenRow = event.oldScreenPosition.row;
  nextScreenRow = event.newScreenPosition.row;

  if currScreenRow == nextScreenRow
    return

  undoCheckpoint = editor.createCheckpoint()
  currLineInfo = getLineInfo(editor, currScreenRow)
  nextLineInfo = getLineInfo(editor, nextScreenRow)

  if ALL_WHITESPACE_REGEXP.test(nextLineInfo.bufferText)
    autoIndentLine(editor, nextLineInfo)
    nextLineInfo = getLineInfo(editor, nextLineInfo.end.screenPos.row)
    event.cursor.setBufferPosition(nextLineInfo.end.bufferPos)

  removeTrailingWhitespace(editor, currLineInfo)
  editor.groupChangesSinceCheckpoint(undoCheckpoint)

handleTextEditor = (editor) ->
  handling = false
  onDidChangeCursorPosition = (event) ->
    # Prevent recursion (we change the cursor position, too).
    if handling
      return
    handling = true
    handleChangeCursorPosition(editor, event)
    handling = false
  editor.onDidChangeCursorPosition(onDidChangeCursorPosition)

atom.workspace.observeTextEditors(handleTextEditor)
