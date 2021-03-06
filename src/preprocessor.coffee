fs = require 'fs'
{EventEmitter} = require 'events'
{pointToErrorLocation} = require './helpers'
StringScanner = require 'StringScanner'

inspect = (o) -> (require 'util').inspect o, no, 9e9, yes


# TODO: better comments
# TODO: support win32-style line endings

@Preprocessor = class Preprocessor extends EventEmitter

  ws = '\\t\\x0B\\f \\xA0\\u1680\\u180E\\u2000-\\u200A\\u202F\\u205F\\u3000\\uFEFF'
  INDENT = '\uEFEF'
  DEDENT = '\uEFFE'
  TERM   = '\uEFFF'
  SAFEBLOCK = /[^\n'"\\\/#`[({\[\]})]+/
  constructor: ->
    # `indents` is an array of successive indentation characters.
    @indents = []
    @context = []
    @ss = new StringScanner ''

  err: (c) ->
    token =
      switch c
        when INDENT
          'INDENT'
        when DEDENT
          'DEDENT'
        when TERM
          'TERM'
        else
          inspect c
    throw new Error "Unexpected " + token

  peek: -> if @context.length then @context[@context.length - 1] else null

  observe: (c) ->
    top = @peek()
    switch c
      # opening token is closing token
      when '"""', '\'\'\'', '"', '\'', '###', '`', '///', '/'
        if top is c then do @context.pop
        else @context.push c
      # strictly opening tokens
      when INDENT, '#', '#{', '[', '(', '{', '\\', 'regexp-[', 'regexp-(', 'regexp-{', 'heregexp-#', 'heregexp-[', 'heregexp-(', 'heregexp-{'
        @context.push c
      # strictly closing tokens
      when DEDENT
        (@err c) unless top is INDENT
        do @context.pop
      when '\n'
        (@err c) unless top in ['#', 'heregexp-#']
        do @context.pop
      when ']'
        (@err c) unless top in ['[', 'regexp-[', 'heregexp-[']
        do @context.pop
      when ')'
        (@err c) unless top in ['(', 'regexp-(', 'heregexp-(']
        do @context.pop
      when '}'
        (@err c) unless top in ['#{', '{', 'regexp-{', 'heregexp-{']
        do @context.pop
      when 'end-\\'
        (@err c) unless top is '\\'
        do @context.pop
      else throw new Error "undefined token observed: " + c
    @context

  p: (s) ->
    if s? then @emit 'data', s
    s

  scan: (r) -> @p @ss.scan r

  processInput = (isEnd) -> (data) ->
    @ss.concat data unless isEnd

    until @ss.eos()
      switch @peek()
        when null, INDENT, '#{', '[', '(', '{'
          if @ss.bol() or @scan /// (?:[#{ws}]* \n)+ ///

            @scan /// (?: [#{ws}]* (\#\#?(?!\#)[^\n]*)? \n )+ ///

            # we might require more input to determine indentation
            return if not isEnd and (@ss.check /// [#{ws}\n]* $ ///)?

            i = 0
            lines = @ss.str.substr(0, @ss.pos).split(/\n/) || ['']
            while i < @indents.length
              indent = @indents[i]
              if @ss.check /// #{indent} ///
                # an existing indent
                @scan /// #{indent} ///
              else if @ss.check /// [^#{ws}] ///
                # we lost an indent
                @indents.splice i--, 1
                @observe DEDENT
                @p "#{DEDENT}#{TERM}"
              else
                # Some ambiguous dedent
                lines = @ss.str.substr(0, @ss.pos).split(/\n/) || ['']
                message = "Syntax error on line #{lines.length}: indention is ambiguous"
                lineLen = @indents.reduce ((l, r) -> l + r.length), 0
                context = pointToErrorLocation @ss.str, lines.length, lineLen
                throw new Error "#{message}\n#{context}"
              i++
            if @ss.check /// [#{ws}]+ [^#{ws}#] ///
              # an indent
              @indents.push @scan /// [#{ws}]+ ///
              @observe INDENT
              @p INDENT

          @scan SAFEBLOCK

          tok = @ss.scan /[\])}]/
          if tok
            ctx = @peek()
            if ctx == INDENT
              @indents.splice @indents.length - 1, 1
              @observe DEDENT
              @p "#{DEDENT}#{TERM}"
            @p tok
            @observe tok
            continue

          if tok = @scan /"""|'''|\/\/\/|###|["'`#[({\\]/
            @observe tok
          else if tok = @scan /\//
            # unfortunately, we must look behind us to determine if this is a regexp or division
            pos = @ss.position()
            if pos > 1
              lastChar = @ss.string()[pos - 2]
              spaceBefore = ///[#{ws}]///.test lastChar
              nonIdentifierBefore = /[\W_$]/.test lastChar # TODO: this should perform a real test
            if pos is 1 or (if spaceBefore then not @ss.check /// [#{ws}=] /// else nonIdentifierBefore)
              @observe '/'
        when '\\'
          if (@scan /[\s\S]/) then @observe 'end-\\'
          # TODO: somehow prevent indent tokens from being inserted after these newlines
        when '"""'
          @scan /(?:[^"#\\]+|""?(?!")|#(?!{)|\\.)+/
          @ss.scan /\\\n/
          if tok = @scan /#{|"""/ then @observe tok
          else if tok = @scan /#{|"""/ then @observe tok
        when '"'
          @scan /(?:[^"#\\]+|#(?!{)|\\.)+/
          @ss.scan /\\\n/
          if tok = @scan /#{|"/ then @observe tok
        when '\'\'\''
          @scan /(?:[^'\\]+|''?(?!')|\\.)+/
          @ss.scan /\\\n/
          if tok = @scan /'''/ then @observe tok
        when '\''
          @scan /(?:[^'\\]+|\\.)+/
          @ss.scan /\\\n/
          if tok = @scan /'/ then @observe tok
        when '###'
          @scan /(?:[^#]+|##?(?!#))+/
          if tok = @scan /###/ then @observe tok
        when '#'
          @scan /[^\n]+/
          if tok = @scan /\n/ then @observe tok
        when '`'
          @scan /[^`]+/
          if tok = @scan /`/ then @observe tok
        when '///'
          @scan /(?:[^[/#\\]+|\/\/?(?!\/)|\\.)+/
          if tok = @scan /#{|\/\/\/|\\/ then @observe tok
          else if @ss.scan /#/ then @observe 'heregexp-#'
          else if tok = @scan /[\[]/ then @observe "heregexp-#{tok}"
        when 'heregexp-['
          @scan /(?:[^\]\/\\]+|\/\/?(?!\/))+/
          if tok = @scan /[\]\\]|#{|\/\/\// then @observe tok
        when 'heregexp-#'
          @ss.scan /(?:[^\n/]+|\/\/?(?!\/))+/
          if tok = @scan /\n|\/\/\// then @observe tok
        #when 'heregexp-('
        #  @scan /(?:[^)/[({#\\]+|\/\/?(?!\/))+/
        #  if tok = @ss.scan /#(?!{)/ then @observe 'heregexp-#'
        #  else if tok = @scan /[)\\]|#{|\/\/\// then @observe tok
        #  else if tok = @scan /[[({]/ then @observe "heregexp-#{tok}"
        #when 'heregexp-{'
        #  @scan /(?:[^}/[({#\\]+|\/\/?(?!\/))+/
        #  if tok = @ss.scan /#(?!{)/ then @observe 'heregexp-#'
        #  else if tok = @scan /[}/\\]|#{|\/\/\// then @observe tok
        #  else if tok = @scan /[[({]/ then @observe "heregexp-#{tok}"
        when '/'
          @scan /[^[/\\]+/
          if tok = @scan /[\/\\]/ then @observe tok
          else if tok = @scan /\[/ then @observe "regexp-#{tok}"
        when 'regexp-['
          @scan /[^\]\\]+/
          if tok = @scan /[\]\\]/ then @observe tok
        #when 'regexp-('
        #  @scan /[^)/[({\\]+/
        #  if tok = @scan /[)/\\]/ then @observe tok
        #  else if tok = @scan /[[({]/ then @observe "regexp-#{tok}"
        #when 'regexp-{'
        #  @scan /[^}/[({\\]+/
        #  if tok = @scan /[}/\\]/ then @observe tok
        #  else if tok = @scan /[[({]/ then @observe "regexp-#{tok}"

    # reached the end of the file
    if isEnd
      @scan /// [#{ws}\n]* $ ///
      while @context.length and INDENT is @peek()
        @observe DEDENT
        @p "#{DEDENT}#{TERM}"
      if @context.length
        # TODO: store offsets of tokens when inserted and report position of unclosed starting token
        throw new Error 'Unclosed ' + (inspect @peek()) + ' at EOF'
      @emit 'end'
      return

    return

  processData: processInput no
  processEnd: processInput yes
  @processSync = (input) ->
    pre = new Preprocessor
    output = ''
    pre.emit = (type, data) -> output += data if type is 'data'
    pre.processData input
    do pre.processEnd
    output
