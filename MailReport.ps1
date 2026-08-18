# --- Default inline image assets ---------------------------------------------
# Load the default header/footer PNGs once per module import. Reading from disk
# every Send-RjReportEmail call would waste IO when a runbook sends several
# reports. $PSScriptRoot resolves to the module root because this file is
# dot-sourced from RealmJoin.RunbookHelper.psm1.
$script:RjRbDefaultHeaderPath = Join-Path $PSScriptRoot 'Assets\Header.png'
$script:RjRbDefaultFooterPath = Join-Path $PSScriptRoot 'Assets\Footer.png'

if (Test-Path -LiteralPath $script:RjRbDefaultHeaderPath -PathType Leaf) {
    try {
        $script:RjRbDefaultHeaderBytes = [IO.File]::ReadAllBytes($script:RjRbDefaultHeaderPath)
    }
    catch {
        Write-Warning "RealmJoin.RunbookHelper: Could not read default header image '$script:RjRbDefaultHeaderPath': $($_.Exception.Message)"
        $script:RjRbDefaultHeaderBytes = $null
    }
}
else {
    $script:RjRbDefaultHeaderBytes = $null
}

if (Test-Path -LiteralPath $script:RjRbDefaultFooterPath -PathType Leaf) {
    try {
        $script:RjRbDefaultFooterBytes = [IO.File]::ReadAllBytes($script:RjRbDefaultFooterPath)
    }
    catch {
        Write-Warning "RealmJoin.RunbookHelper: Could not read default footer image '$script:RjRbDefaultFooterPath': $($_.Exception.Message)"
        $script:RjRbDefaultFooterBytes = $null
    }
}
else {
    $script:RjRbDefaultFooterBytes = $null
}

function Write-RjRbForcedWarning {
    <#
        .SYNOPSIS
        Emits a Write-Warning that bypasses any caller-side $WarningPreference override.

        .DESCRIPTION
        Write-Warning is suppressed at the source when $WarningPreference is
        'SilentlyContinue' or 'Ignore'. In Azure Automation runbooks the default is
        'Continue' so warnings normally do reach the job output, but a runbook or a
        previously imported module may have overridden the preference. To make
        critical user-facing warnings reliable, this helper temporarily forces
        $WarningPreference to 'Continue' for the duration of the write.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $saved = $WarningPreference
    $WarningPreference = 'Continue'
    try {
        Write-Warning $Message
    }
    finally {
        $WarningPreference = $saved
    }
}

function Resolve-RjRbImageSource {
    <#
        .SYNOPSIS
        Resolves an image override to bytes, content-type and filename. Used by
        Send-RjReportEmail to build inline Graph attachments for Header/Footer
        overrides. Accepts a local filesystem path that the caller has already
        resolved (URL handling is intentionally not part of the module).

        .DESCRIPTION
        The image format is detected from the file signature (magic bytes), not from
        the file extension - a renamed non-image (e.g. an HTML error page saved as
        .png) is rejected instead of producing a broken inline attachment.
        Supported formats: PNG, JPEG, GIF.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Image file not found: $Path"
    }

    $bytes = [IO.File]::ReadAllBytes($Path)

    # Detect the actual image format from the file signature; the extension may lie.
    $contentType = $null
    if ($bytes.Length -ge 8 -and
        $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47 -and
        $bytes[4] -eq 0x0D -and $bytes[5] -eq 0x0A -and $bytes[6] -eq 0x1A -and $bytes[7] -eq 0x0A) {
        $contentType = 'image/png'
    }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 -and $bytes[2] -eq 0xFF) {
        $contentType = 'image/jpeg'
    }
    elseif ($bytes.Length -ge 6 -and $bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46 -and $bytes[3] -eq 0x38 -and
        ($bytes[4] -eq 0x37 -or $bytes[4] -eq 0x39) -and $bytes[5] -eq 0x61) {
        $contentType = 'image/gif'
    }

    if (-not $contentType) {
        throw "The file '$Path' is not a PNG, JPEG or GIF image (unrecognized file signature). Use PNG, JPG or GIF."
    }

    [pscustomobject]@{
        Bytes       = $bytes
        ContentType = $contentType
        FileName    = [IO.Path]::GetFileName($Path)
    }
}

function Add-RjRbCellSoftBreaks {
    <#
        .SYNOPSIS
        Inserts zero-width-space break opportunities into overlong unbreakable
        table-cell tokens.

        .DESCRIPTION
        The Outlook Classic (Word) engine does not break long words inside
        table cells; a single unbreakable token wider than its column makes
        Word grow the whole table - and with it the fixed 750px email card -
        past the header/footer banners, which is what leaves a strip beside
        the banner graphic.

        MEASURED (Word 16.x, via an OOXML round-trip of the generated markup):
        Word offers a line-break opportunity ONLY at whitespace, U+002D
        hyphen-minus, U+00AD soft hyphen and U+200B zero-width space. '.', '@',
        '/', ':', '&' and '\' are NOT break opportunities - a 95-character
        registry path measured 664px of minimum width against a 654px column,
        with or without the surrounding <code> element - so the earlier
        exemption of tokens containing them was exactly backwards, and
        'Henrietta.Mueller@fabrikam.com' reached Word as one unbreakable
        30-character run measuring ~236px against the 144px its column was
        allotted. That single token widened the card by ~16px.

        This helper splits every text-node token longer than -MaxRunChars into
        -MaxRunChars sized pieces joined by U+200B. Callers pass the run length
        the target column can actually hold, so the number of inserted breaks
        is the minimum needed. HTML entities are counted and kept as single
        units, so '&amp;' is never split apart, and internal placeholders
        (§...§) are left alone so they still resolve later. Only text nodes are
        touched - never tags, attributes or href values.

        Only Outlook Classic needs the breaks, and only Outlook Classic should
        pay for them: with -ConditionalTwin each affected run is emitted twice,
        the broken copy behind <!--[if mso]> and the original behind the
        downlevel-revealed twin. Every other client therefore keeps a value that
        pastes cleanly, and the duplication is per RUN, not per element - it only
        fires on runs past the limit, which are rare by construction.

        .PARAMETER MaxRunChars
        Longest run left untouched. Callers pass the run length their container
        can actually hold.

        .PARAMETER ConditionalTwin
        Emit an MSO-only twin per broken run instead of breaking the text for
        every client. A caller whose output is ALREADY inside an [if mso] block
        must leave this off - HTML comments do not nest, so a conditional comment
        inside a conditional comment terminates the outer one early and leaks the
        MSO-only markup to everyone.

        Trade-off: without -ConditionalTwin, copying an affected value out of the
        mail carries the invisible U+200B characters along.
    #>
    param(
        [string]$Html,
        [int]$MaxRunChars = 80,
        [switch]$ConditionalTwin
    )
    if ([string]::IsNullOrEmpty($Html)) { return $Html }
    if ($MaxRunChars -lt 6) { $MaxRunChars = 6 }
    $zwsp = [string][char]0x200B
    # A width "character" is a whole HTML entity or a single character.
    $unitPattern = '&(?:[A-Za-z][A-Za-z0-9]{1,9}|#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6});|[\s\S]'
    $twin = $ConditionalTwin.IsPresent
    return [regex]::Replace($Html, '(?<=^|>)[^<>]+(?=<|$)', {
        param($m)
        # Token = a run with no break opportunity Word would honour.
        [regex]::Replace($m.Value, '[^\s\u00AD\u200B-]+', {
            param($t)
            # Never touch the converter's own placeholders - a U+200B inside
            # §INLINECODE§n§ would stop it resolving back to its code span.
            if ($t.Value.Contains([char]0xA7)) { return $t.Value }
            $units = [regex]::Matches($t.Value, $unitPattern)
            if ($units.Count -le $MaxRunChars) { return $t.Value }
            $sb = [System.Text.StringBuilder]::new()
            for ($u = 0; $u -lt $units.Count; $u++) {
                if ($u -gt 0 -and ($u % $MaxRunChars) -eq 0) { [void]$sb.Append($zwsp) }
                [void]$sb.Append($units[$u].Value)
            }
            if (-not $twin) { return $sb.ToString() }
            return "<!--[if mso]>$($sb.ToString())<![endif]--><!--[if !mso]><!-->$($t.Value)<!--<![endif]-->"
        })
    })
}

function ConvertFrom-RjRbMarkdownToHtml {
    <#
        .SYNOPSIS
        Converts Markdown text to HTML with support for common Markdown syntax.

        .DESCRIPTION
        Lightweight Markdown to HTML converter supporting headers, lists, tables, code blocks,
        links, link buttons, images, bold, italic, blockquotes, and horizontal rules.

        .PARAMETER MarkdownText
        The Markdown text to convert to HTML.

        .PARAMETER AccentColor
        Accent color (hex, e.g. '#f8842c') used for table headers and link buttons.
        Defaults to the RealmJoin orange. The value is used verbatim in inline styles -
        callers are expected to validate it (Send-RjRbReportEmail does).

        .PARAMETER TextColor
        Primary text color (hex, e.g. '#011e33') used for list items and code text.
        Defaults to the RealmJoin navy.

        .EXAMPLE
        PS C:\> ConvertFrom-RjRbMarkdownToHtml -MarkdownText "# Hello World`n`nThis is **bold** text."

        .OUTPUTS
        System.String. Returns HTML string.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$MarkdownText,

        [string]$AccentColor = '#f8842c',

        [string]$TextColor = '#011e33'
    )

    # Input validation
    if ([string]::IsNullOrEmpty($MarkdownText)) {
        return ""
    }

    $MarkdownText = $MarkdownText.Trim()
    $html = $MarkdownText

    # Normalize line endings to \n only (remove \r)
    $html = $html -replace "`r`n", "`n"
    $html = $html -replace "`r", "`n"

    # Escape Markdown characters first.
    #
    # ASCII punctuation ONLY, per CommonMark: a backslash before anything else is
    # a literal backslash, not an escape. The previous '\\(.)' swallowed the
    # backslashes of Windows paths and registry keys - 'HKLM:\SOFTWARE\Policies'
    # arrived as 'HKLM:SOFTWAREPolicies', which for a runbook report is both wrong
    # and, with every break opportunity gone, a token Word cannot wrap.
    #
    # The character is encoded as its code point, NOT wrapped in markers. The old
    # form '§ESCAPED§*§ESCAPED§' left the '*' in plain sight, so the emphasis pass
    # further down matched it anyway and produced
    # '§ESCAPED§<em>§ESCAPED§not italic§ESCAPED§</em>§ESCAPED§' - the escape did
    # not escape, and the markers leaked into the mail. Numeric encoding hides the
    # character from every later pattern, which is the whole point of the pass.
    $html = [regex]::Replace($html, '\\([!-/:-@\[-`{-~])', {
        param($m)
        '§ESCAPED§{0}§' -f [int][char]$m.Groups[1].Value
    })

    # Extract and protect code blocks before processing other markdown elements
    # This prevents headers and other markdown syntax inside code blocks from being transformed
    # Store code blocks in an array and replace them with placeholders
    $codeBlocks = @()
    $codeBlockIndex = 0

    # Extract code blocks with language support (handles both ``` and malformed ` variants)
    # Note: Some markdown content may have malformed code blocks with single backtick instead of triple backticks
    # (e.g., `powershell instead of ```powershell). This regex handles both cases by matching 1-3 backticks
    # at the start of a line (with optional indentation).
    $html = $html -replace '(?sm)^\s*`{1,3}(\w+)?\r?\n(.+?)^\s*`{1,3}\s*$', {
        $language = $_.Groups[1].Value
        $code = $_.Groups[2].Value.TrimEnd("`r`n").TrimEnd("`n") -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '\\`', '`'

        $preStyle = "background-color:#e8ebed;padding:20px;border-radius:8px;border:1px solid #e5e7eb;font-family:'SF Mono',Monaco,'Consolas',monospace;margin:20px 0;overflow-x:auto;"
        $preTag = if ($language) {
            "<pre bgcolor=`"#e8ebed`" style=`"$preStyle`"><code class=`"language-$language`" style=`"background:none;border:none;padding:0;font-family:inherit;font-size:inherit;color:$TextColor;`">$code</code></pre>"
        }
        else {
            "<pre bgcolor=`"#e8ebed`" style=`"$preStyle`"><code style=`"background:none;border:none;padding:0;font-family:inherit;font-size:inherit;color:$TextColor;`">$code</code></pre>"
        }

        # Wrap in MSO-only table to add horizontal inset in Outlook Classic
        # (Word engine ignores border-radius, so without this the bg fills edge-to-edge)
        # Use <pre> inside the td to preserve line breaks in Outlook Classic.
        #
        # MEASURED: white-space:pre-wrap DOES work in Word - a 187-character command
        # line wraps at its spaces and the card stays at 750px. Only a run with no
        # break opportunity at all overflows: a 166-character URL measured the card
        # at 992.85px, i.e. 243px past the card, far more than the 96px the content
        # row's gutter columns can absorb. So only such runs are soft-broken, and
        # only in the MSO twin - the <pre> that modern clients get is a separate
        # string and stays byte-for-byte copy-pasteable.
        # 70 chars x ~7.15px (13px Consolas) = 500px, inside the 614px this cell
        # has after its 2x20px padding. 80 measured exactly 654px - on budget with
        # zero margin, and Windows metrics run wider than the Mac measurement, so
        # the threshold keeps a reserve. Ordinary code is untouched: the longest
        # token in a realistic pipeline is ~35 characters.
        $msoCode = Add-RjRbCellSoftBreaks -Html $code -MaxRunChars 70
        $htmlBlock = "<!--[if mso]><table role=`"presentation`" width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" border=`"0`" style=`"margin:20px 0;width:100%;table-layout:fixed;border-collapse:collapse;`"><tr><td bgcolor=`"#e8ebed`" style=`"background-color:#e8ebed;border:1px solid #e5e7eb;padding:20px;`"><pre style=`"margin:0;font-family:Consolas,'Courier New',monospace;font-size:13px;color:$TextColor;white-space:pre-wrap;`">$msoCode</pre></td></tr></table><![endif]--><!--[if !mso]><!-->$preTag<!--<![endif]-->"

        $placeholder = "§CODEBLOCK§$codeBlockIndex§"
        $codeBlocks += $htmlBlock
        $codeBlockIndex++
        return $placeholder
    }

    # Extract and protect inline code before processing other markdown
    $inlineCodeBlocks = @()
    $inlineCodeIndex = 0
    $html = $html -replace '`([^`]+)`', {
        $code = $_.Groups[1].Value -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '\\`', '`'
        $htmlInline = "<code>$code</code>"

        $placeholder = "§INLINECODE§$inlineCodeIndex§"
        $inlineCodeBlocks += $htmlInline
        $inlineCodeIndex++
        return $placeholder
    }

    # Extract and protect link buttons before the generic link processing below
    # Syntax:  [Label](https://url){button}
    # Example: [Approve](url1){button} [Reject](url2){button}
    # Multiple buttons are rendered in the same row.
    # Rounded button corners are only supported in modern clients (e.g. Outlook New, OWA, mobile Outlook app). 
    # Outlook Classic (Word engine) renders square button corners.
    $buttonRows = @()
    $buttonRowIndex = 0
    $html = $html -replace '(?m)^[ \t]*(?:\[[^\]]+\]\([^)]+\)\{\s*button\s*\}[ \t]*)+$', {
        $line = $_.Value
        $buttons = [regex]::Matches($line, '\[([^\]]+)\]\(([^)]+)\)\{\s*button\s*\}')

        $count = $buttons.Count
        $cellPercent = [int]([Math]::Floor(100 / $count))
        $msoCells = [System.Collections.Generic.List[string]]::new()
        $webButtons = [System.Collections.Generic.List[string]]::new()
        $tableReset = 'border:none;border-collapse:collapse;box-shadow:none;border-radius:0;background:none;'
        for ($i = 0; $i -lt $count; $i++) {
            $button = $buttons[$i]
            $label = $button.Groups[1].Value.Trim() -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
            $href = $button.Groups[2].Value.Trim() -replace '&', '&amp;' -replace '"', '&quot;'

            # Outlook Classic (Word engine) buttons are rendered as table cells with 100% width divided equally between them. 
            # To prevent the buttons from sticking together, add left/right padding to all but the outer edges of the button group.
            $msoPad = if ($count -le 1) { 'padding:0;' }
            elseif ($i -eq 0) { 'padding:0 6px 0 0;' }
            elseif ($i -eq ($count - 1)) { 'padding:0 0 0 6px;' }
            else { 'padding:0 6px;' }
            $msoCells.Add("<td width=`"$cellPercent%`" valign=`"top`" style=`"${msoPad}border:none;background:none;`"><table role=`"presentation`" width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" border=`"0`" style=`"width:100%;table-layout:fixed;$tableReset`"><tr><td bgcolor=`"$AccentColor`" align=`"center`" valign=`"middle`" style=`"mso-padding-alt:14px 8px;padding:14px 8px;border:none;`"><a href=`"$href`" style=`"font-family:'Segoe UI',Arial,sans-serif;font-size:16px;font-weight:bold;line-height:16px;color:#ffffff;text-decoration:none;mso-line-height-rule:exactly;`">$label</a></td></tr></table></td>")

            # Modern clients support flexible button widths and rounded corners. 
            # Render buttons as links with padding and background color, wrapped in a flex container to allow wrapping if there are many buttons or the labels are long.
            $webButtons.Add("<a href=`"$href`" target=`"_blank`" rel=`"noopener noreferrer`" style=`"flex:1 1 200px;box-sizing:border-box;margin:6px;background-color:$AccentColor;border-radius:8px;color:#ffffff;font-family:'Miriam Libre','Segoe UI',Arial,sans-serif;font-size:16px;font-weight:700;line-height:1;text-align:center;text-decoration:none;padding:14px 8px;`">$label</a>")
        }

        # Outlook Classic (Word engine) requires tables for complex layouts, so render buttons in a table row with one cell per button.
        # Use a nested table for the button styling to prevent Word from stripping styles on the outer cell.
        $msoRow = "<!--[if mso]><table role=`"presentation`" width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" border=`"0`" style=`"width:100%;table-layout:fixed;$tableReset`"><tr>$([string]::Join('', $msoCells))</tr></table><![endif]-->"
        # Modern email clients support more flexible layouts and better CSS support, so render buttons as styled links in a flex container that allows wrapping if needed.
        $webRow = "<!--[if !mso]><!--><div style=`"display:flex;flex-wrap:wrap;margin:-6px;`">$([string]::Join('', $webButtons))</div><!--<![endif]-->"
        $row = "$msoRow$webRow"

        $placeholder = "§BUTTONROW§$buttonRowIndex§"
        $buttonRows += $row
        $buttonRowIndex++
        return $placeholder
    }

    # Horizontal rules - split per engine. Outlook Classic (Word) does not reliably
    # render <hr> (border CSS suppresses it, the size/color attributes alone draw
    # nothing here), so the mso branch uses a 1-cell table whose top border is the
    # line. That cell would otherwise inherit the data-table rules .content table
    # (border-radius/box-shadow/background -> rounded pill) and .content td
    # (border-bottom -> a second line), so both are reset inline (inline beats the
    # class selectors). Modern clients ignore the mso branch and use the plain <hr>.
    $html = $html -replace '(?m)^(-{3,}|\*{3,}|_{3,})$', '<!--[if mso]><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:16px 0;width:100%;table-layout:fixed;border:0;border-collapse:collapse;background:transparent;mso-table-lspace:0pt;mso-table-rspace:0pt;"><tr><td style="border:0;border-top:2px solid #e5e7eb;font-size:0;line-height:0;mso-line-height-rule:exactly;background:transparent;">&nbsp;</td></tr></table><![endif]--><!--[if !mso]><!--><hr style="border:0;border-top:2px solid #e5e7eb;margin:16px 0;" /><!--<![endif]-->'

    # Headers (all 6 levels) - now safe from code block interference
    # Also supports headers without space after # (e.g., #Header instead of # Header)
    # mso-margin-*-alt mirror the margins for Outlook Classic (the Word engine ignores
    # standard margin on headings, which otherwise glues the next paragraph to the heading).
    $html = $html -replace '(?m)^######\s*(.+)$', '<h6 style="color:#111827;margin-top:15px;margin-bottom:15px;mso-margin-top-alt:15px;mso-margin-bottom-alt:15px;font-size:16px;font-weight:800;">$1</h6>'
    $html = $html -replace '(?m)^#####\s*(.+)$', '<h5 style="color:#111827;margin-top:15px;margin-bottom:15px;mso-margin-top-alt:15px;mso-margin-bottom-alt:15px;font-size:16px;font-weight:800;">$1</h5>'
    $html = $html -replace '(?m)^####\s*(.+)$', '<h4 style="color:#111827;margin-top:15px;margin-bottom:15px;mso-margin-top-alt:15px;mso-margin-bottom-alt:15px;font-size:16px;font-weight:800;">$1</h4>'
    $html = $html -replace '(?m)^###\s*(.+)$', '<h3 style="color:#111827;margin-top:27px;margin-bottom:15px;mso-margin-top-alt:27px;mso-margin-bottom-alt:15px;font-size:18px;font-weight:800;">$1</h3>'
    $html = $html -replace '(?m)^##\s*(.+)$', '<h2 style="color:#111827;margin-top:42px;margin-bottom:15px;mso-margin-top-alt:42px;mso-margin-bottom-alt:15px;font-size:22px;font-weight:800;">$1</h2>'
    # h1 carries a border-bottom; the Word engine drops its margin, gluing the next
    # paragraph to the rule. Recreate the gap with an MSO-only line-height spacer div
    # (the pattern used in the HTML templates) - a spacer *table* adds Word's own
    # space-before/after and overshoots.
    $html = $html -replace '(?m)^#\s*(.+)$', '<h1 style="color:#111827;border-bottom:2px solid #111827;padding-bottom:12px;margin-bottom:15px;mso-margin-top-alt:0;font-size:26px;font-weight:800;">$1</h1><!--[if mso]><div style="line-height:15px;font-size:0;mso-line-height-rule:exactly;">&nbsp;</div><![endif]-->'

    # Bold and Italic (limit to single line to prevent backtracking)
    $html = $html -replace '\*\*([^\n\r*]+)\*\*', '<strong>$1</strong>'
    $html = $html -replace '\*([^\n\r*]+)\*', '<em>$1</em>'
    $html = $html -replace '~~([^\n\r~]+)~~', '<span style="text-decoration:line-through;">$1</span>'

    # Explicit line breaks may by forced with <br>, <br/> or <br />
    $html = $html -replace '(?i)<br\s*/?>', '<br>'

    # Links and Images
    $html = $html -replace '!\[([^\]]*)\]\(([^)]+)\)', '<img src="$2" alt="$1"/>'
    $html = $html -replace '\[([^\]]+)\]\(([^)]+)\)', '<a href="$2" target="_blank" rel="noopener noreferrer" style="color:#3b82f6;text-decoration:underline;">$1</a>'

    # Helper functions
    function Pop-Stack {
        param([ref]$Stack)
        if ($Stack.Value.Count -gt 0) {
            if ($Stack.Value.Count -eq 1) {
                $Stack.Value = @()  # Ensure it's an array
            }
            else {
                $Stack.Value = @($Stack.Value[0..($Stack.Value.Count - 2)])  # Ensure it's an array
            }
        }
    }

    function Update-ListNesting {
        param(
            [int]$TargetLevel,
            [ref]$ListStack,
            [ref]$ProcessedLines,
            [string]$ListType
        )

        $currentLevel = $ListStack.Value.Count

        if ($TargetLevel -gt $currentLevel) {
            for ($n = $currentLevel; $n -lt $TargetLevel; $n++) {
                # Nested lists: no top/bottom margin to prevent extra spacing in Outlook New
                $nestedStyle = if ($ListType -eq 'ul') {
                    'style="margin:0;padding-left:20px;list-style-type:disc;"'
                }
                else {
                    'style="margin:0;padding-left:20px;list-style-type:decimal;"'
                }
                $ProcessedLines.Value += "<$ListType $nestedStyle>"
                $ListStack.Value += $ListType
            }
        }
        elseif ($TargetLevel -lt $currentLevel) {
            for ($n = $currentLevel; $n -gt $TargetLevel; $n--) {
                $closeType = $ListStack.Value[-1]
                $ProcessedLines.Value += "</$closeType>"
                Pop-Stack -Stack $ListStack
            }
        }
    }

    function Close-AllList {
        param(
            [ref]$ListStack,
            [ref]$ProcessedLines,
            [ref]$InUnorderedList,
            [ref]$InOrderedList
        )

        while ($ListStack.Value.Count -gt 0) {
            $listType = $ListStack.Value[-1]
            $closeTag = "</$listType>"
            $ProcessedLines.Value += $closeTag
            Pop-Stack -Stack $ListStack
        }
        $InUnorderedList.Value = $false
        $InOrderedList.Value = $false
    }

    # Single-pass line processing
    $lines = $html -split "`n"
    $processedLines = @()
    $lineCount = $lines.Count

    $inTable = $false
    $inUnorderedList = $false
    $inOrderedList = $false
    $inBlockquote = $false
    # Task list items render as rows of a borderless presentation table
    # rather than <li>s, because Word (Outlook Classic) always paints the
    # marker of the parent <ul> regardless of `list-style:none`.
    $inTaskTable = $false
    $tableAlignments = @()
    $listStack = @()
    $tableRowIndex = 0
    # Index into $processedLines of the most recent <li>. Used to fold
    # continuation lines (indented non-list text below a list item) back
    # into that <li> instead of starting a new paragraph outside the list.
    $lastListItemIndex = -1

    for ($i = 0; $i -lt $lineCount; $i++) {
        $line = $lines[$i]

        # Blockquote processing
        if ($line -match '^>\s*(.*)$') {
            if ($inTable) { $processedLines += '</tbody></table></div>'; $inTable = $false; $tableAlignments = @(); $tableRowIndex = 0 }
            if ($inTaskTable) { $processedLines += '</table>'; $inTaskTable = $false }
            Close-AllList -ListStack ([ref]$listStack) -ProcessedLines ([ref]$processedLines) -InUnorderedList ([ref]$inUnorderedList) -InOrderedList ([ref]$inOrderedList)

            $content = $Matches[1]
            if (-not $inBlockquote) {
                # GitHub-style admonition: first line is "[!TYPE]" alone -> render
                # as a coloured callout instead of a plain blockquote. Body lines
                # that follow are treated like normal blockquote content.
                $admonitionType = $null
                if ($content -match '^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*$') {
                    $admonitionType = $Matches[1].ToUpperInvariant()
                }

                if ($admonitionType) {
                    $palette = switch ($admonitionType) {
                        'NOTE' { @{ Accent = '#3b82f6'; Title = 'Note'; Glyph = '&#9432;' } }
                        'TIP' { @{ Accent = '#10b981'; Title = 'Tip'; Glyph = '&#128161;' } }
                        'IMPORTANT' { @{ Accent = '#8b5cf6'; Title = 'Important'; Glyph = '&#10071;' } }
                        'WARNING' { @{ Accent = '#f59e0b'; Title = 'Warning'; Glyph = '&#9888;' } }
                        'CAUTION' { @{ Accent = '#ef4444'; Title = 'Caution'; Glyph = '&#9940;' } }
                    }
                    # Same MSO/non-MSO wrapper pattern as a plain blockquote, but
                    # no italics and a per-type accent colour on the left border.
                    $processedLines += "<!--[if mso]><table role=`"presentation`" width=`"100%`" cellpadding=`"0`" cellspacing=`"0`" border=`"0`" style=`"margin:15px 0;width:100%;table-layout:fixed;`"><tr><td bgcolor=`"#e8ebed`" style=`"background-color:#e8ebed;border-left:4px solid $($palette.Accent);padding:10px 24px;color:#374151;`" valign=`"top`"><![endif]-->"
                    $processedLines += "<!--[if !mso]><!--><blockquote style=`"border-left:4px solid $($palette.Accent);background-color:#e8ebed;padding:10px 24px;margin:15px 0;color:#374151;border-radius:0 8px 8px 0;`"><!--<![endif]-->"
                    $processedLines += "<p style=`"margin:0 0 8px 0;font-weight:700;color:$($palette.Accent);font-size:14px;`">$($palette.Glyph) $($palette.Title)</p>"
                    $inBlockquote = $true
                    continue
                }

                # MSO-only table wrapper for blockquote background (Word engine ignores background-color on blockquote)
                # Use border-left on a single td rather than a separate narrow td (Outlook enforces min cell width)
                # Hide the <blockquote> from MSO so only the table renders (inline styles override !important in Word engine)
                $processedLines += '<!--[if mso]><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:15px 0;width:100%;table-layout:fixed;"><tr><td bgcolor="#e8ebed" style="background-color:#e8ebed;border-left:4px solid #3b82f6;padding:0 24px;font-style:italic;color:#374151;" valign="top"><![endif]-->'
                $processedLines += '<!--[if !mso]><!--><blockquote style="border-left:4px solid #3b82f6;background-color:#e8ebed;padding:10px 24px;margin:15px 0;font-style:italic;color:#374151;"><!--<![endif]-->'
                $inBlockquote = $true
            }
            if ($content.Trim() -ne '') {
                $processedLines += $content
            }
        }
        # Table processing
        elseif ($line -match '^\|.*\|$') {
            if ($inBlockquote) { $processedLines += '<!--[if !mso]><!--></blockquote><!--<![endif]--><!--[if mso]></td></tr></table><![endif]-->'; $inBlockquote = $false }
            if ($inTaskTable) { $processedLines += '</table>'; $inTaskTable = $false }
            Close-AllList -ListStack ([ref]$listStack) -ProcessedLines ([ref]$processedLines) -InUnorderedList ([ref]$inUnorderedList) -InOrderedList ([ref]$inOrderedList)

            if (-not $inTable) {
                # mso-margin-bottom-alt:0 stops the Word engine from stacking this wrapper's
                # bottom margin on top of the next heading's (large) top margin - Word does
                # not collapse adjacent margins the way browsers/OWA do, so without it the
                # gap after a table looks bigger than the gap after a paragraph.
                $processedLines += '<div class="table-wrapper" style="margin:15px 0;mso-margin-bottom-alt:0;">'
                $processedLines += '<table class="table table-striped" cellpadding="0" cellspacing="0" border="0" width="100%" style="width:100%;border-collapse:collapse;background-color:white;border:1px solid #e8ebed;">'
                $inTable = $true
                $tableRowIndex = 0

                # Outlook Classic renders this table with table-layout:fixed (MSO style
                # block backstop), which defaults to EQUAL column widths - a short
                # column (date) would wrap while a long column wastes space. In fixed
                # layout Word takes column widths from <col> elements, and the
                # converter sees every cell up front - so scan the whole table ahead
                # and emit an MSO-only <col> set with content-proportional widths.
                # Modern clients skip the conditional comment and keep auto layout.
                $colMaxChars = [System.Collections.Generic.List[int]]::new()
                for ($la = $i; $la -lt $lineCount -and $lines[$la] -match '^\|.*\|$'; $la++) {
                    if ($lines[$la] -match '^\|[-:\s\|]+\|$') { continue }   # alignment separator row
                    $laCells = ($lines[$la] -replace '^\|', '' -replace '\|$', '').Split('|')
                    for ($lc = 0; $lc -lt $laCells.Count; $lc++) {
                        # Visible-length estimate: resolve inline-code placeholders to
                        # their real text, strip html tags (links/bold are converted by
                        # now), count entities and escaped pipes as one character.
                        $visible = $laCells[$lc].Trim()
                        $visible = $visible -replace '§INLINECODE§(\d+)§', { 'x' * (($inlineCodeBlocks[[int]$_.Groups[1].Value] -replace '<[^>]+>', '').Length) }
                        # An escape placeholder and an entity each stand for ONE
                        # rendered character - count them as such, or the column
                        # allocator over-estimates and steals width from its
                        # neighbours.
                        $visible = $visible -replace '<[^>]+>', '' -replace '§ESCAPED§\d+§|&[A-Za-z]+;|&#\d+;', 'x'
                        while ($colMaxChars.Count -le $lc) { $colMaxChars.Add(0) }
                        if ($visible.Length -gt $colMaxChars[$lc]) { $colMaxChars[$lc] = $visible.Length }
                    }
                }
                $tableColPcts = @()
                $tableColRunChars = @()
                $tableColPctsPending = $false

                # Horizontal cell padding scales DOWN with the column count.
                # Padding is per column, so it eats the width budget linearly:
                # at the default 2x16px a nine-column table spends 288px of the
                # 654px content width - 44% - on padding alone, before a single
                # character is rendered. MEASURED on the nine-column stress
                # fixture: min-content 670px against a 654px budget, i.e. 16px
                # over, which is exactly the strip that reappeared beside the
                # banner. Soft-breaking cannot recover it - those columns are
                # already at the 6-character floor - so the padding is what has
                # to give. 2x6px brings the same table to ~518px.
                # Every consumer of this number must use THIS variable: the
                # allocator below, the run-length budget, and the emitted <th>
                # and <td> styles. If they drift apart, the allocator promises
                # widths the cells do not have.
                $tableCellPadX = if ($colMaxChars.Count -ge 9) { 6 }
                elseif ($colMaxChars.Count -ge 7) { 8 }
                else { 16 }

                if ($colMaxChars.Count -ge 2) {
                    # Pixel need per column: clamped char count x ~7px (14px
                    # proportional font) plus the 2x16px cell padding. Distribute the
                    # ~650px content width max-min fair: every column that fits keeps
                    # exactly its need (dates never wrap), oversized columns split the
                    # remainder equally among themselves.
                    $colPxNeed = @($colMaxChars | ForEach-Object { [Math]::Min([Math]::Max($_, 3), 60) * 7 + 2 * $tableCellPadX })
                    $colPx = @(0.0) * $colPxNeed.Count
                    $avail = 650.0
                    $active = @(0..($colPxNeed.Count - 1))
                    while ($active.Count -gt 0) {
                        $fair = $avail / $active.Count
                        $fits = @($active | Where-Object { $colPxNeed[$_] -le $fair })
                        if ($fits.Count -eq 0) { foreach ($ci in $active) { $colPx[$ci] = $fair }; break }
                        foreach ($ci in $fits) { $colPx[$ci] = $colPxNeed[$ci]; $avail -= $colPxNeed[$ci] }
                        $active = @($active | Where-Object { $colPxNeed[$_] -gt $fair })
                    }
                    # Integer percentages summing to exactly 100 (largest remainder;
                    # a sub-650px total just scales up proportionally via the divide).
                    # The widths are applied as inline style="width:N%" on the cells
                    # of the table's FIRST row (below) - NOT as <col>/<colgroup>
                    # elements: Word's HTML reader keeps only the first column
                    # element of a run and foster-parents the rest into the first
                    # header cell, silently dropping their widths. Verified three
                    # times via Outlook's save-as-HTML output (bare <col/> run,
                    # [if mso]-wrapped <colgroup>, and a plain unconditional
                    # <colgroup> all got relocated). Inline cell widths are Word's
                    # own native format and are applied reliably; Word uses them as
                    # its fixed column grid and wraps long tokens inside the cell
                    # instead of growing the table past the 750px card. Modern
                    # clients treat them as proportional hints in auto layout
                    # (deliberate, minor rendering change - the proportions are
                    # derived from the same cell contents auto layout would
                    # measure), and .table-wrapper keeps its horizontal scroll on
                    # small screens.
                    $pxSum = ($colPx | Measure-Object -Sum).Sum
                    $raw = @($colPx | ForEach-Object { 100.0 * $_ / $pxSum })
                    $pct = @($raw | ForEach-Object { [int][Math]::Floor($_) })
                    $rest = 100 - ($pct | Measure-Object -Sum).Sum
                    foreach ($ci in (0..($raw.Count - 1) | Sort-Object { [Math]::Floor($raw[$_]) - $raw[$_] })) {
                        if ($rest -le 0) { break }
                        $pct[$ci]++; $rest--
                    }
                    $tableColPcts = $pct
                    # Longest unbreakable run each column can hold without forcing Word
                    # to widen the table: (allocated px - cell padding) / px per char.
                    # 7.6px/char is what Windows Segoe UI MEASURES at 14px for the
                    # digit- and caps-heavy content of a device report; the allocator
                    # above deliberately keeps its own 7px estimate, because that one
                    # only distributes width proportionally and changing it would move
                    # every column percentage. Here the number decides whether a token
                    # fits, so it has to be the pessimistic one - Word for Mac
                    # substitutes a narrower font and would otherwise sign off on
                    # layouts that overflow on Windows.
                    # Floor of 6 keeps pathologically narrow columns sane.
                    $tableColRunChars = @($colPx | ForEach-Object { [Math]::Max(6, [Math]::Floor(($_ - 2 * $tableCellPadX) / 7.6)) })
                    $tableColPctsPending = $true
                }

                # Check for separator line with alignment
                if (($i + 1) -lt $lineCount -and $lines[$i + 1] -match '^\|[-:\s\|]+\|$') {
                    $separatorLine = $lines[$i + 1]
                    $alignmentCells = ($separatorLine -replace '^\|', '' -replace '\|$', '').Split('|')
                    $tableAlignments = @()
                    foreach ($alignCell in $alignmentCells) {
                        $alignCell = $alignCell.Trim()
                        if ($alignCell -match '^:.*:$') { $tableAlignments += 'center' }
                        elseif ($alignCell -match ':$') { $tableAlignments += 'right' }
                        elseif ($alignCell -match '^:') { $tableAlignments += 'left' }
                        else { $tableAlignments += '' }
                    }

                    # Process header row
                    $cells = ($line -replace '^\|', '' -replace '\|$', '').Split('|')
                    if ($cells.Count -gt 0) {
                        $processedLines += "<thead><tr bgcolor=`"$AccentColor`" style=`"background-color:$AccentColor;`">"
                        for ($j = 0; $j -lt $cells.Count; $j++) {
                            $cellRunChars = if ($j -lt $tableColRunChars.Count) { $tableColRunChars[$j] } else { 80 }
                            $cleanCell = Add-RjRbCellSoftBreaks -Html $cells[$j].Trim() -MaxRunChars $cellRunChars -ConditionalTwin
                            if ([string]::IsNullOrWhiteSpace($cleanCell)) { $cleanCell = '&nbsp;' }
                            $alignClass = if ($j -lt $tableAlignments.Count -and $tableAlignments[$j]) { " class=`"text-$($tableAlignments[$j])`"" } else { "" }
                            # width:N% first in the style attr - the header row defines
                            # Word's column grid (see width computation comment above)
                            $widthStyle = if ($tableColPctsPending -and $j -lt $tableColPcts.Count) { "width:$($tableColPcts[$j])%;" } else { '' }
                            $processedLines += "<th$alignClass style=`"${widthStyle}background-color:$AccentColor;color:#ffffff;padding:8px ${tableCellPadX}px;font-weight:600;font-size:14px;`">$cleanCell</th>"
                        }
                        $processedLines += '</tr></thead><tbody>'
                        $tableColPctsPending = $false
                        $i++
                        continue
                    }
                }
            }

            # Regular table row
            $cells = ($line -replace '^\|', '' -replace '\|$', '').Split('|')
            if ($cells.Count -gt 0) {
                $tableRowIndex++
                $rowBgAttr = if ($tableRowIndex % 2 -eq 0) { ' bgcolor="#e8ebed" style="background-color:#e8ebed;"' } else { '' }
                $processedLines += "<tr$rowBgAttr>"
                for ($j = 0; $j -lt $cells.Count; $j++) {
                    $cellRunChars = if ($j -lt $tableColRunChars.Count) { $tableColRunChars[$j] } else { 80 }
                    $cleanCell = Add-RjRbCellSoftBreaks -Html $cells[$j].Trim() -MaxRunChars $cellRunChars -ConditionalTwin
                    if ([string]::IsNullOrWhiteSpace($cleanCell)) { $cleanCell = '&nbsp;' }
                    $alignStyle = if ($j -lt $tableAlignments.Count -and $tableAlignments[$j]) { "text-align:$($tableAlignments[$j]);" } else { "" }
                    $alignClass = if ($j -lt $tableAlignments.Count -and $tableAlignments[$j]) { " class=`"text-$($tableAlignments[$j])`"" } else { "" }
                    # Only set for the first row of a headerless table (no separator
                    # line): that row then defines Word's column grid instead of a thead
                    $widthStyle = if ($tableColPctsPending -and $j -lt $tableColPcts.Count) { "width:$($tableColPcts[$j])%;" } else { '' }
                    $processedLines += "<td$alignClass style=`"${widthStyle}padding:8px ${tableCellPadX}px;border-bottom:1px solid #e8ebed;font-size:14px;color:#2D3748;${alignStyle}`">$cleanCell</td>"
                }
                $processedLines += '</tr>'
                $tableColPctsPending = $false
            }
        }
        # Unordered List processing
        elseif ($line -match '^(\s*)- (.+)$') {
            $indentation = $Matches[1].Length
            $content = $Matches[2]
            $nestLevel = [Math]::Floor($indentation / 2)

            # GitHub-style task list: "- [ ] todo" / "- [x] done". Detect before
            # any further -match calls (the automatic $Matches gets clobbered).
            $isTask = $false
            $taskChecked = $false
            if ($content -match '^\[([ xX])\]\s+(.+)$') {
                $marker = $Matches[1]
                $content = $Matches[2]
                $isTask = $true
                $taskChecked = ($marker -eq 'x' -or $marker -eq 'X')
            }

            if ($isTask) {
                # Tasks live in their own borderless <table> so there is no
                # parent <ul> for Word to draw a marker on. Close anything
                # else that is open first.
                if ($inBlockquote) { $processedLines += '<!--[if !mso]><!--></blockquote><!--<![endif]--><!--[if mso]></td></tr></table><![endif]-->'; $inBlockquote = $false }
                if ($inTable) { $processedLines += '</tbody></table></div>'; $inTable = $false; $tableAlignments = @(); $tableRowIndex = 0 }
                Close-AllList -ListStack ([ref]$listStack) -ProcessedLines ([ref]$processedLines) -InUnorderedList ([ref]$inUnorderedList) -InOrderedList ([ref]$inOrderedList)

                if (-not $inTaskTable) {
                    # margin-left:20px lines the glyph column up with the
                    # bullets of a regular <ul> (which also start ~20px in
                    # from the content edge in both Outlook clients).
                    # border-collapse + explicit border:0 on every cell is
                    # required - Outlook New otherwise paints faint default
                    # cell borders even with border="0" on the table.
                    # table-layout:auto is a no-op in modern clients (a widthless table
                    # computes as auto layout anyway) but shields this table from the
                    # MSO-block "table { table-layout:fixed }" backstop in Outlook
                    # Classic, which would otherwise freeze the glyph column at the
                    # width of the first row.
                    $processedLines += '<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:15px 0 12px 20px;border-collapse:collapse;border:0;background:transparent;table-layout:auto;">'
                    $inTaskTable = $true
                }

                # Unicode ballot box glyphs render reliably across Outlook
                # Classic/New, OWA and mobile clients; <input type="checkbox">
                # does not (Word engine strips form controls).
                #
                # Cell content is wrapped in <p style="margin:0"> because the
                # Word renderer (Outlook Classic) injects its own paragraph
                # with default top/bottom margins around bare text in a <td>,
                # which inflates the row height noticeably.
                $glyph = if ($taskChecked) { '&#9745;' } else { '&#9744;' }
                $glyphColor = if ($taskChecked) { '#10b981' } else { '#6b7280' }
                $processedLines += "<tr><td valign=`"top`" style=`"padding:2px 8px 2px 0;border:0;background:transparent;color:$glyphColor;font-weight:700;line-height:1.5;font-size:16px;`"><p style=`"margin:0;padding:0;`">$glyph</p></td><td valign=`"top`" style=`"padding:2px 0;border:0;background:transparent;line-height:1.5;color:$TextColor;font-size:16px;`"><p style=`"margin:0;padding:0;`">$content</p></td></tr>"
                $lastListItemIndex = $processedLines.Count - 1
                continue
            }

            if ($inBlockquote) { $processedLines += '<!--[if !mso]><!--></blockquote><!--<![endif]--><!--[if mso]></td></tr></table><![endif]-->'; $inBlockquote = $false }
            if ($inTable) { $processedLines += '</tbody></table></div>'; $inTable = $false; $tableAlignments = @(); $tableRowIndex = 0 }
            if ($inTaskTable) { $processedLines += '</table>'; $inTaskTable = $false }
            if ($inOrderedList) { $processedLines += '</ol>'; $inOrderedList = $false }

            # Open first list if needed
            if (-not $inUnorderedList) {
                $processedLines += '<ul style="margin:15px 0 12px 0;padding-left:40px;list-style-type:disc;">'
                $inUnorderedList = $true
                $listStack += 'ul'
            }

            # Handle nesting (nestLevel+1 because nestLevel is 0-based, only update if different)
            $targetLevel = $nestLevel + 1
            if ($targetLevel -ne $listStack.Count) {
                Update-ListNesting -TargetLevel $targetLevel -ListStack ([ref]$listStack) -ProcessedLines ([ref]$processedLines) -ListType 'ul'
            }

            $processedLines += "<li style=`"margin:4px 0;padding-left:8px;line-height:1.5;color:$TextColor;`">$content</li>"
            $lastListItemIndex = $processedLines.Count - 1
        }
        # Ordered List processing
        elseif ($line -match '^(\s*)(\d+)\. (.+)$') {
            if ($inBlockquote) { $processedLines += '<!--[if !mso]><!--></blockquote><!--<![endif]--><!--[if mso]></td></tr></table><![endif]-->'; $inBlockquote = $false }
            if ($inTable) { $processedLines += '</tbody></table></div>'; $inTable = $false; $tableAlignments = @(); $tableRowIndex = 0 }
            if ($inTaskTable) { $processedLines += '</table>'; $inTaskTable = $false }
            if ($inUnorderedList) { $processedLines += '</ul>'; $inUnorderedList = $false }

            $indentation = $Matches[1].Length
            $content = $Matches[3]
            $nestLevel = [Math]::Floor($indentation / 2)

            # Open first list if needed
            if (-not $inOrderedList) {
                # padding-left:40px (instead of 20px) pushes the numbers
                # back into the content area in Outlook New / web renderers,
                # where the default negative marker offset would otherwise let
                # the digits drift left of the heading column.
                $processedLines += '<ol style="margin:15px 0 12px 0;padding-left:40px;list-style-type:decimal;">'
                $inOrderedList = $true
                $listStack += 'ol'
            }

            # Handle nesting (nestLevel+1 because nestLevel is 0-based, only update if different)
            $targetLevel = $nestLevel + 1
            if ($targetLevel -ne $listStack.Count) {
                Update-ListNesting -TargetLevel $targetLevel -ListStack ([ref]$listStack) -ProcessedLines ([ref]$processedLines) -ListType 'ol'
            }

            $processedLines += "<li style=`"margin:4px 0;padding-left:8px;line-height:1.5;color:$TextColor;`">$content</li>"
            $lastListItemIndex = $processedLines.Count - 1
        }
        # Other lines
        else {
            # Continuation of the previous list item: an indented, non-empty line
            # directly below an open <li> belongs to that item, not to a new
            # paragraph outside the list. Append with a <br> and skip the rest
            # of the else branch so the list state is preserved.
            if (($listStack.Count -gt 0 -or $inTaskTable) -and $lastListItemIndex -ge 0 -and
                -not [string]::IsNullOrWhiteSpace($line) -and
                $line -match '^\s+\S' -and
                $line -notmatch '^<h[1-6]') {
                $existing = $processedLines[$lastListItemIndex]
                if ($existing -match '^(.*)</li>$') {
                    $processedLines[$lastListItemIndex] = "$($Matches[1])<br>$($line.Trim())</li>"
                    continue
                }
                # Task-table row: fold continuation into the trailing <td>
                # before the closing </p></td></tr>.
                if ($existing -match '^(.*)</p></td></tr>$') {
                    $processedLines[$lastListItemIndex] = "$($Matches[1])<br>$($line.Trim())</p></td></tr>"
                    continue
                }
            }

            if ($inBlockquote) { $processedLines += '<!--[if !mso]><!--></blockquote><!--<![endif]--><!--[if mso]></td></tr></table><![endif]-->'; $inBlockquote = $false }
            if ($inTable) { $processedLines += '</tbody></table></div>'; $inTable = $false; $tableAlignments = @(); $tableRowIndex = 0 }

            $isHeader = $line -match '^<h[1-6]>'
            $isEmptyLine = [string]::IsNullOrWhiteSpace($line)
            $nextLineIsList = $false
            $nextLineIsHeader = $false

            if ($isEmptyLine -and ($i + 1) -lt $lineCount) {
                for ($j = $i + 1; $j -lt $lineCount; $j++) {
                    $nextLine = $lines[$j]
                    if (-not [string]::IsNullOrWhiteSpace($nextLine)) {
                        $nextLineIsList = ($nextLine -match '^(\s*)- (.+)$') -or ($nextLine -match '^(\s*)(\d+)\. (.+)$')
                        $nextLineIsHeader = ($nextLine -match '^<h[1-6]>')
                        break
                    }
                }
            }

            if ($listStack.Count -gt 0 -and ($isHeader -or ($isEmptyLine -and -not $nextLineIsList -and -not $nextLineIsHeader))) {
                Close-AllList -ListStack ([ref]$listStack) -ProcessedLines ([ref]$processedLines) -InUnorderedList ([ref]$inUnorderedList) -InOrderedList ([ref]$inOrderedList)
            }
            if ($inTaskTable -and ($isHeader -or ($isEmptyLine -and -not $nextLineIsList -and -not $nextLineIsHeader))) {
                $processedLines += '</table>'
                $inTaskTable = $false
            }

            if (-not $isEmptyLine -or $listStack.Count -eq 0) {
                $processedLines += $line
            }
        }
    }

    # Close remaining open structures
    if ($inBlockquote) { $processedLines += '<!--[if !mso]><!--></blockquote><!--<![endif]--><!--[if mso]></td></tr></table><![endif]-->' }
    if ($inTable) { $processedLines += '</tbody></table></div>' }
    if ($inTaskTable) { $processedLines += '</table>' }
    Close-AllList -ListStack ([ref]$listStack) -ProcessedLines ([ref]$processedLines) -InUnorderedList ([ref]$inUnorderedList) -InOrderedList ([ref]$inOrderedList)

    $html = $processedLines -join "`n"

    # Paragraph processing
    $blocks = $html -split "`n`n+"

    $result = @()
    foreach ($block in $blocks) {
        $block = $block.Trim()
        if ($block -eq "") { continue }

        # Check if block starts with an HTML element tag (opening or closing)
        if ($block -match "^<(h[1-6]|ul|ol|table|pre|blockquote|hr)[\s>]" -or
            $block -match "^</(h[1-6]|ul|ol|table|pre|blockquote)>" -or
            $block -match '§CODEBLOCK§' -or
            $block -match '§BUTTONROW§') {
            $result += $block
        }
        # Check if it contains HTML list elements - if so, don't wrap
        elseif ($block -match "<(h[1-6]|ul|ol|li|table|thead|tbody|tr|td|th|pre|code|blockquote|hr|/ul|/ol)[\s>]") {
            $result += $block
        }
        # Check if block is only <br> tags to force line breaks
        elseif ($block -match '^(?:<br>\s*)+$') {
            $breakCount = ([regex]::Matches($block, '<br>')).Count
            for ($b = 0; $b -lt $breakCount; $b++) {
                $result += '<div style="line-height:16px;font-size:0;mso-line-height-rule:exactly;">&nbsp;</div>'
            }
        }
        else {
            $lines = $block -split "`n"
            $nonEmptyLines = @($lines | Where-Object { $_.Trim() -ne "" })
            if ($nonEmptyLines.Count -gt 0) {
                $paragraphContent = $nonEmptyLines -join '<br>'
                $result += "<p style=`"color:#111827;font-size:16px;line-height:1.4;margin-bottom:15px;`">$paragraphContent</p>"
            }
        }
    }

    $html = $result -join "`n`n"

    # Final safety escaping
    $html = $html -replace '&(?![a-zA-Z]{2,8};)(?!#[0-9]{1,7};)(?!#x[0-9a-fA-F]{1,6};)', '&amp;'

    # Restore escaped Markdown characters. Outside code the backslash was markup
    # and is dropped; '\*' renders as a literal '*'.
    $html = [regex]::Replace($html, '§ESCAPED§(\d+)§', {
        param($m)
        [string][char][int]$m.Groups[1].Value
    })

    # Restore protected blocks from placeholders. String.Replace, NOT -replace:
    # the stored fragments are user content, and regex substitution would treat
    # $-sequences in them as substitution tokens ($_ = whole input, $& = match,
    # $1 = group), duplicating the entire document or corrupting the output.
    #
    # Escapes are resolved INSIDE each fragment as well. Escaping runs before the
    # code spans and blocks are lifted out, so their content still carries
    # §ESCAPED§ markers at this point, while the restore pass above only ever saw
    # $html - which no longer contains them. Anything escaped inside backticks
    # therefore used to reach the reader verbatim, e.g.
    # 'HKLM:§ESCAPED§S§ESCAPED§OFTWARE'.
    # Inside code the backslash is content, not markup (CommonMark does not
    # process escapes in code spans), so it is put back - except for '|', which
    # GFM does treat as escapable inside a table cell even within code.
    $restoreEscapes = {
        param([string]$Fragment)
        return [regex]::Replace($Fragment, '§ESCAPED§(\d+)§', {
            param($m)
            $ch = [char][int]$m.Groups[1].Value
            if ($ch -eq '|') { return '|' }
            return '\' + $ch
        })
    }

    for ($i = 0; $i -lt $inlineCodeBlocks.Count; $i++) {
        $html = $html.Replace("§INLINECODE§$i§", (& $restoreEscapes $inlineCodeBlocks[$i]))
    }

    for ($i = 0; $i -lt $codeBlocks.Count; $i++) {
        $html = $html.Replace("§CODEBLOCK§$i§", (& $restoreEscapes $codeBlocks[$i]))
    }

    for ($i = 0; $i -lt $buttonRows.Count; $i++) {
        $html = $html.Replace("§BUTTONROW§$i§", $buttonRows[$i])
    }

    # Final width safety net for everything OUTSIDE data tables and code blocks:
    # prose, list and task-list items, blockquotes, admonitions and inline code.
    # Those have no column budget, and a long run there widens the Outlook Classic
    # card just as a table cell would - MEASURED per construct against the 654px
    # content column: a 95-character registry path in inline code needs 670px, the
    # same path in a blockquote 660px. Both drop to exactly 654px once the run can
    # break. 60 characters is the bound: inline code MEASURES ~8.2px per
    # character, so 80 still left the column 3px over at 657px; 60 gives ~508px
    # including the code span's own padding, and 462px for 14px body text.
    #
    # Only Outlook Classic gets the breaks (-ConditionalTwin), so a value copied
    # out of any other client is unchanged.
    #
    # Two kinds of region are skipped:
    #   <pre>            - the code-block MSO twin is bounded by its own call at
    #                      70, and the copy modern clients get has to stay
    #                      byte-for-byte pasteable.
    #   [if ...] blocks  - conditional comments do not nest. Table cells were
    #                      already twinned above, so running over them again
    #                      would put a conditional inside a conditional, which
    #                      terminates the outer one early and leaks MSO-only
    #                      markup into every client. The cost of skipping them is
    #                      that text living ONLY inside such a block - button
    #                      labels are the one real case - stays unbounded.
    #
    # Ordinary prose never reaches 60 characters without a break opportunity, so
    # this only ever fires on paths, URLs, hashes and identifiers - exactly the
    # runs that would otherwise widen the card.
    $guarded = [regex]::Split($html, '(?s)(<pre[^>]*>.*?</pre>|<!--\[if [^\]]*\]>.*?<!\[endif\]-->)')
    for ($p = 0; $p -lt $guarded.Count; $p++) {
        if ($guarded[$p] -notmatch '^(<pre|<!--\[if )') {
            $guarded[$p] = Add-RjRbCellSoftBreaks -Html $guarded[$p] -MaxRunChars 60 -ConditionalTwin
        }
    }
    $html = -join $guarded

    return $html
}

function Get-RjRbReportEmailBody {
    <#
        .SYNOPSIS
        Builds the RealmJoin-branded HTML email body used for report delivery.

        .DESCRIPTION
        Assembles the static HTML template, injects the converted Markdown content, and renders
        optional attachment metadata as well as tenant information into the footer section.

        .PARAMETER Subject
        Subject of the email, used for the HTML <title> element.

        .PARAMETER HtmlContent
        HTML fragment generated from Markdown that will be embedded in the email body.

        .PARAMETER MarkdownText
        Markdown text that will be converted to HTML and embedded in the email body.

        .PARAMETER Attachments
        Optional list of attachment file paths to surface in the "Attached Files" section.

        .PARAMETER TenantDisplayName
        Optional tenant display name shown in the tenant information box.

        .PARAMETER ReportVersion
        Optional report version string rendered in the tenant information box.

        .PARAMETER IncludeTenantInfo
        If set, includes the tenant information box in the email body, showing the TenantDisplayName and ReportVersion values.

        .PARAMETER IncludeHeader
        If set, includes the RealmJoin-branded header in the email body.

        .PARAMETER HeaderAltText
        Optional alt text for the header image. Defaults to 'RealmJoin - Insights on Demand'.

        .PARAMETER IncludeFooter
        If set, includes the RealmJoin-branded footer in the email body.

        .PARAMETER FooterLink
        Optional URL that overrides the hyperlink wrapping the footer image. Defaults to
        'https://www.realmjoin.com'. The supplied value is used verbatim as the href and
        title attributes of the footer anchor element.

        .PARAMETER FooterAltText
        Optional alt text for the footer image. Defaults to
        'RealmJoin - Companion to Intune - Application Lifecycle and Management Automation Platform'. The supplied value is used verbatim as the alt attribute of the footer image.

        .PARAMETER AccentColor
        Accent color (hex) used for table headers, buttons, accent borders and the
        horizontal rule. Defaults to the RealmJoin orange '#f8842c' - with the default,
        the generated HTML is identical to previous module versions. The value is used
        verbatim in the CSS/inline styles; callers are expected to validate it
        (Send-RjRbReportEmail does).

        .PARAMETER TextColor
        Primary text color (hex) used for body text, headings and code. Defaults to
        the RealmJoin navy '#011e33' - with the default, the generated HTML is
        identical to previous module versions.

        .OUTPUTS
        System.String. Returns the composed HTML email body.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [string]$HtmlContent,

        [string]$MarkdownText,

        [string[]]$Attachments = @(),

        [string]$TenantDisplayName,

        [string]$ReportVersion,

        [switch]$IncludeTenantInfo,

        [switch]$IncludeHeader,

        [string]$HeaderAltText = 'RealmJoin - Insights on Demand',

        [switch]$IncludeFooter,

        [string]$FooterLink = 'https://www.realmjoin.com',

        [string]$FooterAltText = 'RealmJoin - Companion to Intune - Application Lifecycle and Management Automation Platform - Visit https://www.realmjoin.com',

        [string]$AccentColor = '#f8842c',

        [string]$TextColor = '#011e33'
    )

    if ([string]::IsNullOrEmpty($HtmlContent) -and -not [string]::IsNullOrEmpty($MarkdownText)) {
        $HtmlContent = ConvertFrom-RjRbMarkdownToHtml -MarkdownText $MarkdownText -AccentColor $AccentColor -TextColor $TextColor
    }

    if (-not $Attachments) {
        $Attachments = @()
    }

    # === MSO CARD GEOMETRY =====================================================
    # For Outlook Classic the card is an outer 750px table holding ONE cell, and
    # inside it each section (header banner / content / footer banner) is its own
    # nested 750px table.
    #
    # Why the banners get their own tables: the Word engine does not implement
    # table-layout at all (measured). A table's rendered grid is max(declared
    # width, min-content width), and every row of one table shares ONE column
    # grid. So while a banner image sat in the same table as the content, content
    # too wide for the 654px budget widened the banner's cell too, while the image
    # stayed pinned at its 750px width attribute - and that difference is the
    # strip beside the banner. Measured with identical content: shared grid ->
    # banner cell 767.20px against a 749.33px image; own table -> 750.00px flat.
    #
    # Why the outer table is still needed: Word imports the content table as
    # AUTOFIT-TO-WINDOW, not as a fixed width - measured via the Word object
    # model, the banner tables come in as "preferred width points" 562.5pt while
    # the content table comes in as "preferred width percent" with Word's 9999999
    # autofit sentinel, whatever px width the markup declares. Left as a top-level
    # table it therefore stretches to the full Outlook reading pane. Nesting it in
    # a fixed 750px cell bounds that autofit; an inner width:100% wrapper does NOT
    # (measured, identical autofit result).
    #
    # Each nested table stays inside its existing div (.header / .content /
    # .footer) so no two tables are adjacent siblings - Word merges directly
    # adjacent tables back into one grid, which would reinstate the coupling.
    #
    # The content table's 48px side margins are gutter COLUMNS, not cell padding.
    # Word cannot redistribute padding, so content that overflows its column
    # pushes the whole table wider; it CAN take width out of a gutter column.
    # Measured with identical overflowing content: padding -> 767.20px grid,
    # gutter columns -> 750.33px with the right gutter shaved to 32px. That turns
    # a broken card edge into a slightly narrower gutter and absorbs up to 96px
    # of overflow. NOTE: this rationale lives here as a PowerShell comment on
    # purpose - an HTML comment inside a <!--[if mso]> block terminates the
    # conditional early (HTML comments do not nest), which leaks the MSO-only
    # markup into every other client.
    $msoGutterCell = '<td width="48" style="width:48px;font-size:1px;line-height:1px;" valign="top">&nbsp;</td>'
    $msoSectionTableOpen = '<table role="presentation" cellspacing="0" cellpadding="0" border="0" width="750" style="width:750px;border-collapse:collapse;">'

    return @"
<!DOCTYPE html>
<html lang="en" xmlns="http://www.w3.org/1999/xhtml" xmlns:v="urn:schemas-microsoft-com:vml" xmlns:o="urn:schemas-microsoft-com:office:office">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="color-scheme" content="light dark">
    <meta name="supported-color-schemes" content="light dark">
    <!--[if gte mso 9]><xml><o:OfficeDocumentSettings><o:AllowPNG/><o:PixelsPerInch>96</o:PixelsPerInch></o:OfficeDocumentSettings></xml><![endif]-->
    <title>$Subject</title>
    <!--[if !mso]><!-->
    <link href="https://fonts.googleapis.com/css2?family=Miriam+Libre:wght@400;700&display=swap" rel="stylesheet">
    <!--<![endif]-->
    <!-- Base styles for ALL clients (including Dark Mode for modern clients) -->
<style type="text/css">
    /* === RESET & BASICS === */
    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
        font-family: 'Miriam Libre', -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif;
        line-height: 1.6;
        color: $TextColor;
        background-color: #e8ebed;
        padding: 20px;
    }

    /* === CONTAINER === */
    .email-container {
        max-width: 750px;
        margin: 0 auto;
        background-color: #ffffff;
        border-radius: 12px;
        box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
        overflow: hidden;
    }

    /* === HEADER === */
    .header {
        display: block;
        line-height: 0;
        font-size: 0;
    }
    .header img.header-img {
        display: block;
        width: 100%;
        max-width: 750px;
        height: auto;
        border: 0;
        outline: none;
        text-decoration: none;
    }

    /* === CONTENT === */
    .content {
        padding: 48px;
        background-color: #ffffff;
    }

    .tenant-info {
        background: #e8ebed;
        border: 1px solid #e0e7ff;
        border-left: 4px solid $AccentColor;
        padding: 10px 20px;
        margin-top: 32px;
        border-radius: 8px;
        font-size: 14px;
    }

    .tenant-info strong {
        color: $TextColor;
        font-weight: 600;
    }

    .content h1 {
        color: #111827;
        border-bottom: 2px solid #111827;
        padding-bottom: 12px;
        margin-bottom: 15px;
        font-size: 26px;
        line-height: 1.4;
        font-weight: 800;
    }

    .content h2 {
        color: #111827;
        margin-top: 42px;
        margin-bottom: 15px;
        font-size: 22px;
        line-height: 1.4;
        font-weight: 800;
    }

    .content h3 {
        color: #111827;
        margin-top: 27px;
        margin-bottom: 15px;
        font-size: 18px;
        line-height: 1.4;
        font-weight: 800;
    }

    .content h4,
    .content h5 {
        color: #111827;
        margin-top: 15px;
        margin-bottom: 15px;
        font-size: 16px;
        line-height: 1.4;
        font-weight: 800;
    }

    .content p {
        color: #111827;
        font-size: 16px;
        line-height: 1.4;
        margin-bottom: 15px;
    }

    .content ul {
        margin-top: 15px;
        margin-left: 0;
        margin-bottom: 12px;
        list-style-type: disc;
        padding-left: 20px;
    }

    .content ol {
        margin-top: 15px;
        margin-left: 0;
        margin-bottom: 12px;
        list-style-type: decimal;
        padding-left: 20px;
    }

    .content li {
        margin-top: 4px;
        margin-left: 0;
        color: $TextColor;
        line-height: 1.5;
        margin-bottom: 4px;
        padding-left: 8px;
    }

    /* === TABLES === */
    .table-wrapper {
        overflow-x: auto;
        -webkit-overflow-scrolling: touch;
        margin: 15px 0;
    }

    .content table {
        width: 100%;
        border-collapse: collapse;
        margin: 0;
        background-color: white;
        border-radius: 8px;
        overflow: hidden;
        box-shadow: 0 1px 3px 0 rgba(0, 0, 0, 0.1);
    }

    .content th {
        background: $AccentColor !important;
        color: #ffffff !important;
        padding: 8px 16px;
        text-align: left;
        font-weight: 600;
        font-size: 14px;
        text-transform: uppercase;
    }

    .content td {
        padding: 8px 16px;
        border-bottom: 1px solid #e8ebed;
        font-size: 14px;
        color: #2D3748;
    }

    .content .text-center { text-align: center !important; }
    .content .text-right  { text-align: right  !important; }
    .content .text-left   { text-align: left; }

    .content tr:nth-child(even) {
        background-color: #e8ebed;
    }

    .content blockquote {
        border-left: 4px solid #3b82f6;
        background: #e8ebed;
        padding: 20px 24px;
        margin-top: 15px;
        margin-bottom: 15px;
        border-radius: 0 8px 8px 0;
        font-style: italic;
        color: #374151;
    }

    /* Fix spacing after blockquote */
    .content blockquote + p {
        margin-top: 15px !important;
    }

    /* === CODE === */
    .content code {
        background-color: #e8ebed;
        padding: 2px 8px;
        border-radius: 4px;
        font-family: 'SF Mono', Monaco, 'Consolas', monospace;
        font-size: 0.875em;
        color: $TextColor;
        border: 1px solid #e5e7eb;
    }

    .content pre {
        background-color: #e8ebed;
        padding: 20px;
        border-radius: 8px;
        overflow-x: auto;
        margin: 20px 0;
        border: 1px solid #e5e7eb;
        font-family: 'SF Mono', Monaco, 'Consolas', monospace;
    }

    /* === HR (Horizontal Rule) === */
    .content hr {
        border: none;
        border-top: 2px solid #e5e7eb;
        margin: 24px 0;
    }

    /* === STRONG & EM === */
    .content strong {
        font-weight: 600;
        color: #111827;
    }

    .content em {
        font-style: italic;
        color: #374151;
    }

    /* === LINKS === */
    .content a {
        color: #3b82f6;
        text-decoration: underline;
    }

    .content a:hover {
        color: #2563eb;
    }

    /* === ATTACHMENTS === */
    .attachments {
        background: #e8ebed;
        border: 1px solid #e0e7ff;
        border-left: 4px solid $AccentColor;
        border-radius: 8px;
        padding: 10px 20px;
        margin-top: 10px;
    }

    .attachments h3 {
        color: $TextColor;
        margin-top: 0;
        font-size: 14px;
        font-weight: 600;
    }

    .attachment-list {
        margin: 0 0 16px 0;
        padding: 0;
    }

    .attachment-item {
        background-color: white;
        border: 1px solid #e0e7ff;
        border-radius: 6px;
        padding: 8px 12px;
        margin-bottom: 3px;
        font-size: 14px;
    }

    .attachments p {
        margin-bottom: 0;
        font-size: 14px;
    }

    /* === FOOTER === */
    /* Footer mirrors the header: a single self-contained graphic referenced
       via cid:footer in an inline image element, optionally wrapped in an
       anchor so the whole block is clickable. No CSS/HTML background-image
       on the cell - that would trigger Outlook's "external pictures" prompt
       even when the CID is attached. */
    .footer {
        display: block;
        line-height: 0;
        font-size: 0;
    }
    .footer a {
        display: block;
        border: 0;
        outline: none;
        text-decoration: none;
    }
    .footer img.footer-img {
        display: block;
        width: 100%;
        max-width: 750px;
        height: auto;
        border: 0;
        outline: none;
        text-decoration: none;
    }

        @media (max-width: 768px) {
        body { padding: 10px; }
        .email-container {
            max-width: 100%;
            border-radius: 8px;
        }
        .content { padding: 24px 20px; }
        .content h1 { font-size: 20px; line-height: 1.4; }
        .content h2 { font-size: 18px; line-height: 1.4; }
        .content h3 { font-size: 16px; line-height: 1.4; }
        .content h4, .content h5 { font-size: 16px; line-height: 1.4; }
        .content p { font-size: 16px; line-height: 1.4; }
        .table-wrapper { margin: 15px 0; }
        .content table { font-size: 14px; min-width: 500px; }
        .content th, .content td { padding: 6px 8px; }
        .tenant-info, .attachments { padding: 16px 20px; font-size: 13px; }
    }

    /* === TABLET === */
    @media (min-width: 769px) and (max-width: 1024px) {
        .email-container { max-width: 750px; }
        .content { padding: 36px; }
    }

    /* === DESKTOP === */
    @media (min-width: 1025px) {
        .email-container { max-width: 750px; }
    }

    /* === DARK MODE ([data-ogsb]/[data-ogsc] annotations) ===
       These attributes are injected by the Outlook.com / OWA / New Outlook
       dark-mode transform - NOT by Outlook Classic. The Word engine
       re-colors internally at render time without touching the DOM and does
       not support attribute selectors at all, so these rules can only ever
       match in the web/New Outlook renderers, as a counterweight to their
       color inversion. A selector only matches where the transform actually
       inverted an explicit inline background (bgcolor attribute or inline
       background-color); elements without one (body, .email-container,
       .content) never receive data-ogsb, so those selectors below are inert
       today - kept for parity should the markup ever gain inline
       backgrounds. Do NOT add inline backgrounds to body/.email-container
       just to activate them: Gmail re-interprets body-level backgrounds and
       could tint the whole page. Outlook Classic dark mode simply
       auto-inverts our inline bgcolors (acceptable; the light VML page
       background around the inverted card remains - known cosmetic
       mismatch, out of scope). !important is required because the dark-mode
       transform writes inline styles that would otherwise win. */
    body[data-ogsb] { background-color: #1a1a1a !important; }

    .email-container[data-ogsb],
    .content[data-ogsb] { background-color: #2d2d2d !important; }

    .tenant-info[data-ogsb],
    .attachments[data-ogsb] { background-color: #2d2d2d !important; border-color: #4a4a4a !important; }

    .attachment-item[data-ogsb] { background-color: #2d2d2d !important; border-color: #4a4a4a !important; }

    .content table[data-ogsb] { background-color: #3a3a3a !important; }
    .content tr[data-ogsb]:nth-child(even) { background-color: #404040 !important; }

    .content code[data-ogsb],
    .content pre[data-ogsb] { background-color: #404040 !important; border-color: #4a4a4a !important; }

    /* === DARK MODE (New Outlook, modern clients) === */
    @media (prefers-color-scheme: dark) {
        body { background-color: #1a1a1a !important; }

        .email-container, .content {
            background-color: #2d2d2d !important;
            color: #e5e5e5 !important;
        }

        /* Header image keeps its native rendering in dark mode (image already has dark background). */

        h1, h2, h3, p, span, strong, div, li, td, blockquote {
            color: #e5e5e5 !important;
        }

        h1 {
            border-bottom: 2px solid #e5e5e5 !important;
        }

        .tenant-info {
            background: linear-gradient(135deg, #2d2d2d 0%, #3a3a3a 100%) !important;
            border: 1px solid #4a4a4a !important;
            border-left-color: $AccentColor !important;
        }

        .content table {
            background-color: #3a3a3a !important;
        }

        .content td {
            border-bottom-color: #4a4a4a !important;
        }

        .content th {
            background: $AccentColor !important;
            color: #ffffff !important;
        }

        .content tr:nth-child(even) {
            background-color: #404040 !important;
        }

        .attachments {
            background: linear-gradient(135deg, #2d2d2d 0%, #3a3a3a 100%) !important;
            border: 1px solid #4a4a4a !important;
            border-left-color: $AccentColor !important;
        }

        .attachment-item {
            background-color: #2d2d2d !important;
            border-color: #4a4a4a !important;
        }

        .content code, .content pre {
            background-color: #404040 !important;
            color: #e5e5e5 !important;
            border-color: #4a4a4a !important;
        }

        .content blockquote {
            background: linear-gradient(135deg, #2d2d2d 0%, #3a3a3a 100%) !important;
            border-left-color: $AccentColor !important;
        }
    }
</style>

<!-- Outlook Classic Fixes (only for MSO) -->
<!--[if mso]>
<style type="text/css">
    /* Force Light Mode for Outlook Classic. The surround is deliberately
       WHITE here (not #e8ebed like modern clients): Word lays the mail out
       on its Letter page model (~627px usable), so the 750px card overflows
       the page to the right - a tiled grey background would only cover the
       page area and leave a white strip beside the card (patchwork effect).
       A uniform white surround with the card's 1px border looks clean;
       centering is impossible in Classic for the same reason (card wider
       than Word's page content area). Modern clients keep the grey,
       centered layout from the main style block. */
    body { background-color: #ffffff; }
    /* .email-container is hidden from Word behind an [if !mso] wrapper - the card
       is the three MSO tables below, so no width rule for it here.
       The divs only carry the tables now: strip every source of vertical space so
       the three tables stack seamlessly. A gap here would read as a hairline
       between banner and content. */
    .header, .content, .footer {
        margin: 0;
        padding: 0;
        mso-margin-top-alt: 0;
        mso-margin-bottom-alt: 0;
        mso-line-height-rule: exactly;
    }
    .header, .footer { font-size: 0; line-height: 0; }
    .content { background-color: #ffffff; }

    /* MSO Font Fallback - Outlook Classic cannot load Google Fonts */
    body, p, li, td, th, h1, h2, h3, h4, h5, h6, div, span, a, blockquote {
        font-family: 'Segoe UI', Arial, Helvetica, sans-serif !important;
    }

    /* MSO table spacing.
       CORRECTION - the previous version of this comment claimed that
       table-layout:fixed "makes Word honor declared widths and wrap long cell
       values natively at the cell boundary" and called fixed layout "the actual
       wrapping mechanism". Both halves are false, measured twice: Word does not
       implement table-layout at all (an OOXML round-trip of this markup never
       emits <w:tblLayout>, and the same table measures an identical grid under
       fixed and under auto). A table's rendered grid is
       max(declared width, min-content width) - declared widths are treated
       strictly as preferences and the content minimum always wins.
       Believing this comment is what mis-scoped the real wrapping mechanism:
       Word offers a line break ONLY at whitespace, '-', U+00AD and U+200B, so
       the only thing that actually keeps a wide table inside the card is the
       U+200B insertion in Add-RjRbCellSoftBreaks, backed by the 48px gutter
       columns of the MSO content row, which Word CAN shrink.
       The declarations below are kept because they are measured inert here and
       cost nothing, and because deleting them has no measured upside on the one
       client that matters (Outlook Classic on Windows); mso-table-lspace/rspace
       are the part that does real work.
       Still true and worth keeping: Word applies element and class selectors
       reliably, but descendant selectors like ".content table" only
       unreliably - never hang a critical rule on a descendant selector here. */
    table { mso-table-lspace: 0pt; mso-table-rspace: 0pt; border-collapse: collapse; table-layout: fixed; }
    .table { table-layout: fixed; }

    /* MSO Heading Spacing - Word engine uses its own spacing without these */
    h1 { mso-margin-top-alt: 0; mso-margin-bottom-alt: 15px; mso-line-height-rule: exactly; }
    h2 { mso-margin-top-alt: 42px; mso-margin-bottom-alt: 15px; mso-line-height-rule: exactly; }
    h3 { mso-margin-top-alt: 27px; mso-margin-bottom-alt: 15px; mso-line-height-rule: exactly; }
    h4, h5, h6 { mso-margin-top-alt: 15px; mso-margin-bottom-alt: 15px; mso-line-height-rule: exactly; }

    /* MSO Paragraph Spacing */
    p { mso-margin-top-alt: 0; mso-margin-bottom-alt: 15px; }

    /* MSO tenant-info / attachments box - table wrapper handles styling, suppress on div.
       Dead for module-generated mail (these divs exist only in non-mso branches) -
       kept as insurance for caller-supplied HtmlContent. */
    .tenant-info, .attachments {
        border: none !important;
        border-left: none !important;
        background-color: transparent !important;
        background: transparent !important;
        padding: 0 !important;
        margin: 0 !important;
    }

    /* MSO Blockquote - table wrapper handles the border-left, suppress on blockquote itself */
    blockquote {
        border-left: none !important;
        background-color: transparent !important;
        padding: 0 !important;
        margin: 0 !important;
    }

    /* MSO List Fixes - Use standard specificity */
    .content ul {
        list-style-type: disc;
        margin-left: 0;
        padding-left: 20px;
    }
    .content ol {
        list-style-type: decimal;
        margin-left: 0;
        padding-left: 20px;
    }
    .content li {
        margin-left: 0;
        padding-left: 8px;
    }

    /* MSO HR Fix */
    hr { mso-line-height-rule: exactly; height: 0; }

</style>
<![endif]-->
</head>
<body>

    <!--[if mso]>
    <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="750" align="center" style="width:750px;border-collapse:collapse;border:1px solid #d1d5db;">
    <tr>
    <td width="750" style="width:750px;background-color:#ffffff;">
    <![endif]-->
    <!--[if !mso]><!-->
    <div class="email-container">
    <!--<![endif]-->
        $(if ($IncludeHeader) {
            @"
        <div class='header'>
            <!--[if mso]>
            $msoSectionTableOpen
            <tr>
            <td width="750" style="width:750px;padding:0;font-size:0;line-height:0;">
            <![endif]-->
            <!-- keep src/alt/width of the mso and non-mso img in sync -->
            <!--[if mso]><img src='cid:header' alt='$HeaderAltText' width='750' style='width:750px;display:block;border:0;' /><![endif]-->
            <!--[if !mso]><!--><img class='header-img' src='cid:header' alt='$HeaderAltText' width='750' /><!--<![endif]-->
            <!--[if mso]></td></tr></table><![endif]-->
        </div>
"@
        })

        <div class="content">
            <!--[if mso]>
            $msoSectionTableOpen
            <tr>
            $msoGutterCell
            <td width="654" style="width:654px;padding:48px 0;" valign="top">
            <![endif]-->

            $($HtmlContent)

            $(if ($IncludeTenantInfo) {
                @"
            <!--[if mso]>
            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="margin-top:32px;width:100%;table-layout:fixed;border-collapse:collapse;"><tr>
            <td bgcolor="#e8ebed" style="background-color:#e8ebed;border-left:4px solid $AccentColor;padding:6px 20px;font-size:14px;" valign="top">
            <![endif]-->
            <!--[if !mso]><!-->
            <div class="tenant-info" style="background:#e8ebed;border:1px solid #e0e7ff;border-left:4px solid $AccentColor;padding:10px 20px;border-radius:8px;font-size:14px;margin-top:32px;">
            <!--<![endif]-->
                <p style="margin:0;padding:0;mso-line-height-rule:exactly;">
"@
            })

            $(if ($IncludeTenantInfo -and -not [string]::IsNullOrEmpty($TenantDisplayName)) {
                    "<strong>Tenant:</strong> $($TenantDisplayName)"
            })

            $(if ($IncludeTenantInfo -and -not [string]::IsNullOrEmpty($TenantDisplayName) -and -not [string]::IsNullOrEmpty($ReportVersion)) {
                "<br>"
            })
            
            $(if ($IncludeTenantInfo -and -not [string]::IsNullOrEmpty($ReportVersion)) {
                "<strong>Report Version:</strong> $($ReportVersion)<br><strong>Generated:</strong> $([System.Threading.Thread]::CurrentThread.CurrentCulture = 'en-US'; Get-Date -Format "dddd, MMMM d, yyyy HH:mm")"
            })
            
            $(if ($IncludeTenantInfo) {
                @'
                </p>
            <!--[if !mso]><!-->
            </div>
            <!--<![endif]-->
            <!--[if mso]>
            </td></tr></table>
            <![endif]-->
'@
            })

            $(if (@($Attachments).Count -gt 0) {
            @"

            <!--[if mso]>
            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="width:100%;table-layout:fixed;"><tr><td style="font-size:1px;line-height:16px;height:16px;">&nbsp;</td></tr></table>
            <table role="presentation" cellspacing="0" cellpadding="0" border="0" width="100%" style="width:100%;table-layout:fixed;border-collapse:collapse;"><tr>
            <td bgcolor="#e8ebed" style="background-color:#e8ebed;border-left:4px solid $AccentColor;padding:6px 20px;font-size:14px;" valign="top">
            <![endif]-->
            <!--[if !mso]><!-->
            <div class="attachments" style="background:#e8ebed;border:1px solid #e0e7ff;border-left:4px solid $AccentColor;border-radius:8px;padding:10px 20px;margin-top:16px;">
            <!--<![endif]-->
                <h3 style="margin:0 0 6px 0;padding:0;mso-margin-top-alt:0;mso-margin-bottom-alt:6px;">Attached Files</h3>
                <div class="attachment-list">
                    $(($Attachments | ForEach-Object { "<div class='attachment-item' style='background-color:white;border:1px solid #e0e7ff;border-radius:6px;padding:8px 12px;margin-bottom:3px;font-size:14px;'>$(Split-Path $_ -Leaf)</div>" }) -join "`n                    ")
                </div>
                <p><strong>Note:</strong> The attachments contain additional information from the generated report and can be used for more in-depth analysis.</p>
            <!--[if !mso]><!-->
            </div>
            <!--<![endif]-->
            <!--[if mso]>
            </td></tr></table>
            <![endif]-->
"@
            })
            <!--[if mso]>
            </td>
            $msoGutterCell
            </tr>
            </table>
            <![endif]-->
        </div>

        $(if ($IncludeFooter) {
            @"
        <div class="footer">
            <!--[if mso]>
            $msoSectionTableOpen
            <tr>
            <td width="750" style="width:750px;padding:0;font-size:0;line-height:0;">
            <![endif]-->
            <a href="$FooterLink" target="_blank" title="Visit $FooterLink" style="display:block;border:0;outline:none;text-decoration:none;">
                <!-- keep src/alt/width of the mso and non-mso img in sync -->
                <!--[if mso]><img src="cid:footer" alt="$FooterAltText" width="750" border="0" style="width:750px;display:block;border:0;" /><![endif]-->
                <!--[if !mso]><!--><img class="footer-img" src="cid:footer" alt="$FooterAltText" width="750" border="0" style="display:block;width:100%;max-width:750px;height:auto;border:0;outline:none;text-decoration:none;" /><!--<![endif]-->
            </a>
            <!--[if mso]></td></tr></table><![endif]-->
        </div>
"@
        })
    <!--[if !mso]><!-->
    </div>
    <!--<![endif]-->
    <!--[if mso]>
    </td>
    </tr>
    </table>
    <![endif]-->
</body>
</html>
"@
}

function Get-RjRbMimeTypeFromExtension {
    <#
        .SYNOPSIS
        Returns the MIME type for a given file extension.

        .DESCRIPTION
        Maps common file extensions used for tenant data exports to their appropriate MIME types.
        Supports CSV, Excel, JSON, XML, TXT, and other common formats.

        .PARAMETER FilePath
        The file path to determine the MIME type for.

        .EXAMPLE
        PS C:\> Get-RjRbMimeTypeFromExtension -FilePath "C:\temp\report.csv"
        Returns: text/csv

        .EXAMPLE
        PS C:\> Get-RjRbMimeTypeFromExtension -FilePath "C:\temp\data.xlsx"
        Returns: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet

        .OUTPUTS
        System.String. Returns the MIME type string.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $extension = [System.IO.Path]::GetExtension($FilePath).ToLower()

    $mimeTypes = @{
        '.csv'  = 'text/csv'
        '.txt'  = 'text/plain'
        '.json' = 'application/json'
        '.xml'  = 'application/xml'
        '.xlsx' = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        '.xls'  = 'application/vnd.ms-excel'
        '.pdf'  = 'application/pdf'
        '.zip'  = 'application/zip'
        '.html' = 'text/html'
        '.htm'  = 'text/html'
        '.log'  = 'text/plain'
        '.md'   = 'text/markdown'
    }

    if ($mimeTypes.ContainsKey($extension)) {
        return $mimeTypes[$extension]
    }
    else {
        # Default to binary stream for unknown types
        return 'application/octet-stream'
    }
}

function Send-RjRbReportEmail {
    <#
        .SYNOPSIS
        Sends a RealmJoin-branded HTML email (converted from Markdown) via Microsoft Graph.

        .DESCRIPTION
        Send-RjRbReportEmail builds an HTML email from Markdown content, inlines a RealmJoin-styled HTML template (including light/dark logos), attaches optional files, and sends the message using the Microsoft Graph API (Invoke-MgGraphRequest).

        .PARAMETER EmailFrom
        The sender user id (user principal name or id) used for the Graph /users/{id}/sendMail call.

        .PARAMETER EmailTo
        Recipient email address(es). Can be a single address or multiple comma-separated addresses (string).
        The function sends individual emails to each recipient for privacy reasons.
        Whitespace and empty entries are automatically removed.

        .PARAMETER Subject
        Subject line for the email message.

        .PARAMETER MarkdownContent
        Report content in Markdown format. The function performs a lightweight conversion of Markdown
        to HTML and places the result into the themed HTML template used for the email body.

        .PARAMETER Attachments
        Optional array of file paths to include as attachments. Files that exist will be read,
        base64-encoded and included as file attachments. Missing files are logged and skipped.

        .PARAMETER FallbackAttachments
        Optional smaller attachment set used when the regular set exceeds the size budget
        (-MaxAttachmentBytes) or the send attempt with the regular set fails for every
        recipient. Without this parameter there is no fallback - a failed send throws
        immediately. Replaces the former inline runbook helper Send-RjRbGuardedReportEmail.

        .PARAMETER FallbackMarkdownContent
        Markdown body used when the fallback attachment set is sent. Defaults to
        -MarkdownContent when omitted.

        .PARAMETER MaxAttachmentBytes
        Raw size budget for the regular attachment set (default 2.5MB - stays safely below
        the ~4 MB Graph sendMail request limit after base64 encoding, HTML body and inline
        branding image overhead). Only evaluated when -FallbackAttachments is provided.

        .PARAMETER TenantDisplayName
        Optional display name for the tenant/organization that will be shown in the email footer
        and tenant info box.

        .PARAMETER ReportVersion
        Optional string describing the report version. Will be shown in the tenant-info block.

        .PARAMETER HeaderImage
        Optional local filesystem path to a PNG/JPG/GIF that overrides the bundled
        default header graphic. The runbook is responsible for resolving any URL/blob
        beforehand (e.g. via Get-AzStorageBlobContent) and passing the resulting local
        file path. If the path is missing, unreadable, or has an unsupported extension,
        a warning is written and the bundled default header is used instead - the send
        is not aborted.

        Recommended dimensions: 750 px width PNG (matches the email-container width and
        the bundled default). Larger images scale down responsively; significantly
        different aspect ratios may look distorted on narrow viewports.

        .PARAMETER FooterImage
        Optional local filesystem path that overrides the bundled default footer graphic.
        Same handling and fallback behaviour as -HeaderImage.

        The footer is rendered as a single <img> wrapped in <a href="https://www.realmjoin.com">,
        so the whole graphic is the clickable target. Any branding text, logo, or URL hint
        you want in the footer must already be baked into the supplied PNG (see
        Tests/Build-FooterAsset.ps1 for how the bundled default is composed).

        Recommended dimensions: 750 px width PNG (same as -HeaderImage).

        .PARAMETER FooterLink
        Optional URL that overrides the hyperlink wrapping the footer image. Defaults to
        'https://www.realmjoin.com'. The supplied value is used verbatim as the href and
        title attributes of the footer anchor element.

        .PARAMETER NoHeader
        Suppress the header graphic entirely.

        .PARAMETER NoFooter
        Suppress the footer graphic and the overlay tagline/links entirely.

        .PARAMETER AccentColor
        Optional accent color override (6-digit hex, e.g. '#0052cc') for table headers,
        buttons, accent borders and the horizontal rule. When empty or invalid, the
        default RealmJoin orange '#f8842c' is used - an invalid value writes a warning
        and never aborts the send. With no override the generated email is identical
        to previous module versions.

        .PARAMETER TextColor
        Optional primary text color override (6-digit hex) for body text, headings and
        code. When empty or invalid, the default RealmJoin navy '#011e33' is used -
        same fallback behaviour as -AccentColor.

        .PARAMETER UseNativeGraphRequest
        Send the message via the native Microsoft.Graph cmdlet Invoke-MgGraphRequest
        instead of the module's Invoke-RjRbRestMethodGraph wrapper. The wrapper remains
        the default; use this switch in environments where Invoke-MgGraphRequest is
        preferred (e.g. when the caller has authenticated via Connect-MgGraph rather
        than Connect-RjRbGraph).

        .EXAMPLE
        PS C:\> Send-RjReportEmail -EmailFrom "reports@contoso.com" -EmailTo "alice@contoso.com" -Subject "Weekly Report" -MarkdownContent "# Hello`nReport body..."

        .EXAMPLE
        PS C:\> Send-RjReportEmail -EmailFrom "reports@contoso.com" -EmailTo "alice@contoso.com, bob@contoso.com, team@contoso.com" -Subject "Inventory" -MarkdownContent (Get-Content .\report.md -Raw) -Attachments @('C:\temp\report.csv') -TenantDisplayName 'Contoso Ltd' -ReportVersion 'v1.2.3'

        .INPUTS
        None. All parameters are provided as arguments; this function does not accept pipeline input.

        .OUTPUTS
        None. The function sends email and writes verbose/log messages. On failure it throws an exception.

        .NOTES
        Dependencies:
        - Default path (recommended): uses the module's own Invoke-RjRbRestMethodGraph /
          Connect-RjRbGraph and has no external module dependency.
        - Optional path with -UseNativeGraphRequest: requires the Microsoft.Graph.Authentication
          module to be available in the runbook environment (cmdlets Get-MgContext,
          Connect-MgGraph, Invoke-MgGraphRequest). Declare it explicitly in the consuming
          runbook, e.g.:
            #Requires -Modules @{ModuleName = "Microsoft.Graph.Authentication"; ModuleVersion = "2.37.0"}

    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$EmailFrom,

        [Parameter(Mandatory = $true)]
        [string]$EmailTo,

        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [string]$MarkdownContent,

        [string[]]$Attachments = @(),

        [string[]]$FallbackAttachments,

        [string]$FallbackMarkdownContent,

        [long]$MaxAttachmentBytes = 2.5MB,

        [bool]$saveToSentItems = $true,

        [string]$TenantDisplayName,

        [string]$ReportVersion,

        # Override paths are NOT strictly validated at parameter binding so that a
        # missing/unreadable override falls back to the bundled default instead of
        # aborting the whole send. Resolve errors are caught below.
        [string]$HeaderImage,

        [string]$FooterImage,

        [string]$FooterLink = 'https://www.realmjoin.com',

        [switch]$NoHeader,

        [switch]$NoFooter,

        # Color overrides are NOT strictly validated at parameter binding so that an
        # invalid value falls back to the default instead of aborting the whole send.
        [string]$AccentColor,

        [string]$TextColor,

        [switch]$UseNativeGraphRequest
    )

    # Parse and clean email addresses from EmailTo parameter
    # Split by comma, trim whitespace, remove empty entries
    # Important: Wrap in @() to ensure we always get an array (StrictMode-friendly)
    $emailRecipients = @(
        $EmailTo -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    )

    if ($emailRecipients.Count -eq 0) {
        throw "No valid email recipients found in EmailTo parameter."
    }

    Write-RjRbLog -Message "Parsed $($emailRecipients.Count) recipient(s) from EmailTo parameter" -Verbose

    # --- Resolve optional color overrides -----------------------------------
    # Invalid values fall back to the template defaults (warning, never abort).
    $rjRbColorParams = @{}
    foreach ($colorOverride in @(
            @{ Name = 'AccentColor'; Value = $AccentColor },
            @{ Name = 'TextColor'; Value = $TextColor })) {
        if ([string]::IsNullOrWhiteSpace($colorOverride.Value)) { continue }
        $candidate = $colorOverride.Value.Trim()
        if ($candidate -match '^#[0-9A-Fa-f]{6}$') {
            $rjRbColorParams[$colorOverride.Name] = $candidate
        }
        else {
            Write-RjRbForcedWarning -Message "$($colorOverride.Name) '$($colorOverride.Value)' is not a 6-digit hex color (e.g. '#0052cc') - using the default color instead."
        }
    }

    # --- Attachment size guard (optional fallback set) ----------------------
    # Replaces the former inline runbook helper Send-RjRbGuardedReportEmail: when the
    # regular attachment set exceeds the raw size budget, the fallback set is sent
    # instead; when the send with the regular set fails for every recipient, one retry
    # with the fallback set is attempted. Both paths delegate to a recursive call that
    # carries no fallback parameters, so the recursion depth is always 1.
    $sizeLimitHint = "If the attachments exceed the email size limit, choose a different report file format or enable the download link option (CreateDownloadLink) to deliver the files."
    $fallbackSet = @($FallbackAttachments | Where-Object { $_ })
    $regularSet = @($Attachments | Where-Object { $_ })
    $hasFallback = ($fallbackSet.Count -gt 0) -and ($regularSet.Count -gt 0)

    $fallbackRetryParams = $null
    if ($hasFallback) {
        $fallbackRetryParams = @{}
        foreach ($boundParam in $PSBoundParameters.GetEnumerator()) { $fallbackRetryParams[$boundParam.Key] = $boundParam.Value }
        $null = $fallbackRetryParams.Remove('FallbackAttachments')
        $null = $fallbackRetryParams.Remove('FallbackMarkdownContent')
        $null = $fallbackRetryParams.Remove('MaxAttachmentBytes')
        $fallbackRetryParams['Attachments'] = $fallbackSet
        if (-not [string]::IsNullOrEmpty($FallbackMarkdownContent)) { $fallbackRetryParams['MarkdownContent'] = $FallbackMarkdownContent }

        # Graph sendMail rejects the whole request at ~4 MB; attachments count
        # base64-encoded (+33%), plus HTML body and inline branding images. Above the
        # raw budget the fallback set is sent directly.
        $totalBytes = ($regularSet | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { (Get-Item -LiteralPath $_).Length } | Measure-Object -Sum).Sum
        if (-not $totalBytes) { $totalBytes = 0 }
        if ($totalBytes -gt $MaxAttachmentBytes) {
            # Pick a unit that doesn't round small values to "0 MB"
            $totalDisplay = if ($totalBytes -ge 1MB) { "$([math]::Round($totalBytes / 1MB, 2)) MB" } else { "$([math]::Round($totalBytes / 1KB, 1)) KB" }
            $budgetDisplay = if ($MaxAttachmentBytes -ge 1MB) { "$([math]::Round($MaxAttachmentBytes / 1MB, 2)) MB" } else { "$([math]::Round($MaxAttachmentBytes / 1KB, 1)) KB" }
            Write-Output "The attachments total $totalDisplay and exceed the email attachment budget of $budgetDisplay - sending the reduced attachment set instead."
            try {
                Send-RjRbReportEmail @fallbackRetryParams
                return
            }
            catch {
                throw "Failed to send email report: $($_.Exception.Message). $sizeLimitHint"
            }
        }
    }

    # Convert Markdown to HTML using helper function
    $htmlContent = ConvertFrom-RjRbMarkdownToHtml -MarkdownText $MarkdownContent @rjRbColorParams

    Write-RjRbLog -Message "Successfully converted Markdown content to HTML" -Verbose

    # Prepare email parameters
    $emailAttachments = @()
    $validatedAttachments = @()
    foreach ($file in $Attachments) {
        if (Test-Path $file) {
            try {
                $contentBytes = [IO.File]::ReadAllBytes($file)
                $content = [Convert]::ToBase64String($contentBytes)
                $mimeType = Get-RjRbMimeTypeFromExtension -FilePath $file
                $emailAttachments += @{
                    "@odata.type"  = "#microsoft.graph.fileAttachment"
                    "name"         = (Split-Path $file -Leaf)
                    "contentType"  = $mimeType
                    "contentBytes" = $content
                }
                $validatedAttachments += $file
                Write-RjRbLog -Message "Added attachment: $(Split-Path $file -Leaf) (MIME type: $mimeType)" -Verbose
            }
            catch {
                Write-RjRbForcedWarning -Message "Could not read attachment '$file': $($_.Exception.Message). Skipping."
                Write-RjRbLog -Message "Attachment read failed for '$file': $($_.Exception.Message)" -Verbose
            }
        }
        else {
            Write-RjRbLog -Message "Attachment file not found: $file" -Verbose
        }
    }

    # --- Inline branding images (CID attachments) ---
    # Graph treats inline images as regular fileAttachment entries with isInline=true
    # and a stable contentId that the HTML references via <img src="cid:..."> /
    # background:url('cid:...'). PNG/JPG is preferred for cross-client rendering
    # (Outlook Classic does not render SVG reliably).
    $includeHeader = -not $NoHeader.IsPresent
    $includeFooter = -not $NoFooter.IsPresent

    if ($NoHeader.IsPresent -and $HeaderImage) {
        Write-RjRbForcedWarning -Message "HeaderImage was provided but will be ignored because -NoHeader is set."
    }

    if ($NoFooter.IsPresent -and $FooterLink -ne 'https://www.realmjoin.com') {
        Write-RjRbForcedWarning -Message "FooterLink was provided but will be ignored because -NoFooter is set."
    }

    if ($NoFooter.IsPresent -and $FooterImage) {
        Write-RjRbForcedWarning -Message "FooterImage was provided but will be ignored because -NoFooter is set."
    }

    if ($includeHeader) {
        $headerBytes = $null
        $headerContentType = $null
        $headerFileName = $null

        if ($HeaderImage) {
            try {
                $headerAsset = Resolve-RjRbImageSource -Path $HeaderImage
                $headerBytes = $headerAsset.Bytes
                $headerContentType = $headerAsset.ContentType
                $headerFileName = $headerAsset.FileName
            }
            catch {
                Write-RjRbForcedWarning -Message ("Could not load custom HeaderImage from '$HeaderImage'. " +
                    "Underlying error: $($_.Exception.Message). " +
                    "Falling back to the bundled default header graphic.")
                Write-RjRbLog -Message "HeaderImage override failed for '$HeaderImage' - underlying error: $($_.Exception.Message)" -Verbose
            }
        }

        if (-not $headerBytes) {
            if ($script:RjRbDefaultHeaderBytes) {
                $headerBytes = $script:RjRbDefaultHeaderBytes
                $headerContentType = 'image/png'
                $headerFileName = 'Header.png'
            }
            else {
                Write-RjRbLog -Message "Default header asset not found at $script:RjRbDefaultHeaderPath - skipping header graphic" -Verbose
                $includeHeader = $false
            }
        }

        if ($includeHeader) {
            if ($headerBytes.Length -gt 3MB) {
                Write-RjRbForcedWarning -Message "Header image is $([Math]::Round($headerBytes.Length / 1MB, 2)) MB; Graph sendMail caps total request size at 4 MB."
            }
            $emailAttachments += @{
                "@odata.type"  = "#microsoft.graph.fileAttachment"
                "name"         = $headerFileName
                "contentType"  = $headerContentType
                "contentBytes" = [Convert]::ToBase64String($headerBytes)
                "contentId"    = "header"
                "isInline"     = $true
            }
        }
    }

    if ($includeFooter) {
        $footerBytes = $null
        $footerContentType = $null
        $footerFileName = $null

        if ($FooterImage) {
            try {
                $footerAsset = Resolve-RjRbImageSource -Path $FooterImage
                $footerBytes = $footerAsset.Bytes
                $footerContentType = $footerAsset.ContentType
                $footerFileName = $footerAsset.FileName
            }
            catch {
                Write-RjRbForcedWarning -Message ("Could not load custom FooterImage from '$FooterImage'. " +
                    "Underlying error: $($_.Exception.Message). " +
                    "Falling back to the bundled default footer graphic.")
                Write-RjRbLog -Message "FooterImage override failed for '$FooterImage' - underlying error: $($_.Exception.Message)" -Verbose
            }
        }

        if (-not $footerBytes) {
            if ($script:RjRbDefaultFooterBytes) {
                $footerBytes = $script:RjRbDefaultFooterBytes
                $footerContentType = 'image/png'
                $footerFileName = 'Footer.png'
            }
            else {
                Write-RjRbLog -Message "Default footer asset not found at $script:RjRbDefaultFooterPath - skipping footer graphic" -Verbose
                $includeFooter = $false
            }
        }

        if ($includeFooter) {
            if ($footerBytes.Length -gt 3MB) {
                Write-RjRbForcedWarning -Message "Footer image is $([Math]::Round($footerBytes.Length / 1MB, 2)) MB; Graph sendMail caps total request size at 4 MB."
            }
            $emailAttachments += @{
                "@odata.type"  = "#microsoft.graph.fileAttachment"
                "name"         = $footerFileName
                "contentType"  = $footerContentType
                "contentBytes" = [Convert]::ToBase64String($footerBytes)
                "contentId"    = "footer"
                "isInline"     = $true
            }
        }
    }

    $htmlBody = Get-RjRbReportEmailBody `
        -Subject $Subject `
        -HtmlContent $htmlContent `
        -Attachments $validatedAttachments `
        -TenantDisplayName $TenantDisplayName `
        -ReportVersion $ReportVersion `
        -IncludeTenantInfo `
        -IncludeHeader:$includeHeader `
        -IncludeFooter:$includeFooter `
        -FooterLink $FooterLink `
        @rjRbColorParams

    # --- Ensure a Graph connection is active --------------------------------
    # Send-RjRbReportEmail is typically the first/only Graph touchpoint in a
    # runbook, so we lazily establish a connection here if none is active.
    # The probe is intentionally permission-free: we only inspect local auth
    # state (script-scope auth headers / Get-MgContext), no network call.
    if ($UseNativeGraphRequest) {
        $mgContext = $null
        try { $mgContext = Get-MgContext -ErrorAction SilentlyContinue } catch { }
        if (-not $mgContext) {
            Write-RjRbLog -Message "No active Microsoft.Graph context detected - calling Connect-MgGraph -Identity -NoWelcome" -Verbose
            try {
                Connect-MgGraph -Identity -NoWelcome -ErrorAction Stop
            }
            catch {
                throw "Auto-connect via Connect-MgGraph -Identity failed: $($_.Exception.Message)"
            }
        }
    }
    else {
        if (-not (Test-Path Variable:Script:RjRbGraphAuthHeaders)) {
            Write-RjRbLog -Message "No active RjRbGraph token detected - calling Connect-RjRbGraph" -Verbose
            try {
                Connect-RjRbGraph -ErrorAction Stop
            }
            catch {
                throw "Auto-connect via Connect-RjRbGraph failed: $($_.Exception.Message)"
            }
        }
    }

    # Send individual emails to each recipient for privacy
    $successfulSends = 0
    $failedSends = 0
    $failedRecipients = @()

    foreach ($recipient in $emailRecipients) {
        try {
            Write-RjRbLog -Message "Sending email to: $recipient" -Verbose

            $message = @{
                subject      = $Subject
                body         = @{
                    contentType = "HTML"
                    content     = $htmlBody
                }
                toRecipients = @(
                    @{
                        emailAddress = @{
                            address = $recipient
                        }
                    }
                )
            }

            if ($emailAttachments.Count -gt 0) {
                $message.attachments = $emailAttachments
            }

            # Send via Graph API
            $body = @{ message = $message; saveToSentItems = $saveToSentItems }
            if ($UseNativeGraphRequest) {
                # Native Graph cmdlet path: requires the caller to have an active
                # Microsoft.Graph session (e.g. via Connect-MgGraph). The wrapper's
                # JSON encoding does not run here, so we serialise the body ourselves.
                $Uri = "https://graph.microsoft.com/v1.0/users/$($EmailFrom)/sendMail"
                $jsonBody = $body | ConvertTo-Json -Depth 10
                Invoke-MgGraphRequest -Uri $Uri -Method POST -Body $jsonBody -ContentType "application/json" -ErrorAction Stop
            }
            else {
                $Resource = "/users/$($EmailFrom)/sendMail"
                Invoke-RjRbRestMethodGraph -Resource $Resource -Method POST -Body $body -ErrorAction Stop
            }

            Write-RjRbLog -Message "Email sent successfully to $recipient" -Verbose
            $successfulSends++
        }
        catch {
            $failedSends++
            $failedRecipients += $recipient
            Write-RjRbLog -Message "Failed to send email to ${recipient}: $($_.Exception.Message)" -Verbose
            Write-Error "Failed to send email to ${recipient}: $($_.Exception.Message)" -ErrorAction Continue
        }
    }

    # Summary logging
    Write-RjRbLog -Message "Email sending completed: $successfulSends successful, $failedSends failed out of $($emailRecipients.Count) total recipient(s)" -Verbose

    if ($failedSends -gt 0) {
        $failedList = $failedRecipients -join ", "
        Write-RjRbLog -Message "Failed recipients: $failedList" -Verbose

        if ($successfulSends -eq 0) {
            # Safety net: retry once with the fallback set if the full set was just attempted
            if ($hasFallback) {
                Write-Output "Sending the email with all attachments failed - retrying with the reduced attachment set..."
                try {
                    Send-RjRbReportEmail @fallbackRetryParams
                    return
                }
                catch {
                    throw "Failed to send email report (retry with the reduced attachment set also failed): $($_.Exception.Message). $sizeLimitHint"
                }
            }
            throw "Failed to send email to all recipients: $failedList"
        }
        else {
            Write-RjRbForcedWarning -Message "Some emails failed to send. Failed recipients: $failedList"
        }
    }
}

function Get-RjRbBrandingMailParams {
    <#
        .SYNOPSIS
        Resolves the tenant email branding settings into Send-RjReportEmail parameters.

        .DESCRIPTION
        Downloads the custom header/footer image configured via the RJReport.Branding.*
        tenant settings to a temp file, validates it (HTTPS only, PNG/JPEG/GIF by file
        signature, size cap) and returns a hashtable ready to splat into
        Send-RjReportEmail / Send-RjRbGuardedReportEmail.

        A missing setting, a broken URL or an invalid image NEVER fails the report send:
        the affected key is simply omitted (warning logged) and the module falls back to
        the bundled default graphics. Images are downloaded once per run - reuse the
        returned hashtable for every email sent by this job.

        .PARAMETER HeaderImageUrl
        Public HTTPS URL of the custom header image (RJReport.Branding.HeaderImageUrl).

        .PARAMETER FooterImageUrl
        Public HTTPS URL of the custom footer image (RJReport.Branding.FooterImageUrl).

        .PARAMETER FooterLink
        URL the footer image links to (RJReport.Branding.FooterLink).

        .PARAMETER AccentColor
        Accent color override (RJReport.Branding.AccentColor). Passed through to
        Send-RjReportEmail, which validates the value and falls back to the default
        on an invalid color.

        .PARAMETER TextColor
        Text color override (RJReport.Branding.TextColor). Same handling as -AccentColor.

        .PARAMETER TimeoutSec
        Download timeout per image in seconds.

        .PARAMETER MaxImageBytes
        Maximum accepted image file size. Branding images count against the ~4 MB Graph
        sendMail request limit together with the report attachments, so they must stay small.
    #>
    param(
        [string]$HeaderImageUrl,
        [string]$FooterImageUrl,
        [string]$FooterLink,
        [string]$AccentColor,
        [string]$TextColor,
        [int]$TimeoutSec = 30,
        [long]$MaxImageBytes = 200KB
    )

    $brandingParams = @{}
    if (-not [string]::IsNullOrWhiteSpace($FooterLink)) {
        $brandingParams.FooterLink = $FooterLink.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($AccentColor)) {
        $brandingParams.AccentColor = $AccentColor.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($TextColor)) {
        $brandingParams.TextColor = $TextColor.Trim()
    }

    $images = @(
        @{ Kind = 'header'; Url = $HeaderImageUrl; ParamName = 'HeaderImage' },
        @{ Kind = 'footer'; Url = $FooterImageUrl; ParamName = 'FooterImage' }
    )

    foreach ($image in $images) {
        if ([string]::IsNullOrWhiteSpace($image.Url)) { continue }
        $url = $image.Url.Trim()
        $tempFile = $null
        try {
            $uri = [System.Uri]$url
            if ($uri.Scheme -ne 'https') {
                throw "Only HTTPS URLs are supported (got '$url')."
            }

            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) `
                ("RjRbBranding-$($image.Kind)-" + [System.Guid]::NewGuid().ToString('N') + '.tmp')

            # Ensure TLS 1.2 on Windows PowerShell 5.1 (no-op on PowerShell 7)
            [System.Net.ServicePointManager]::SecurityProtocol = `
                [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

            $previousProgressPreference = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'
            try {
                Invoke-WebRequest -Uri $url -OutFile $tempFile -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
            }
            finally {
                $ProgressPreference = $previousProgressPreference
            }

            $fileItem = Get-Item -LiteralPath $tempFile -ErrorAction Stop
            if ($fileItem.Length -eq 0) { throw "The downloaded file is empty." }
            if ($fileItem.Length -gt $MaxImageBytes) {
                throw "The image is $([math]::Round($fileItem.Length / 1KB, 1)) KB and exceeds the $([math]::Round($MaxImageBytes / 1KB, 0)) KB limit for inline email images."
            }

            # Determine the actual image format from the file signature - the URL may have a
            # wrong extension or none at all, and Send-RjReportEmail validates by extension.
            $magic = New-Object byte[] 8
            $stream = [System.IO.File]::OpenRead($tempFile)
            try { [void]$stream.Read($magic, 0, 8) } finally { $stream.Dispose() }

            $extension = $null
            if ($magic[0] -eq 0x89 -and $magic[1] -eq 0x50 -and $magic[2] -eq 0x4E -and $magic[3] -eq 0x47 -and
                $magic[4] -eq 0x0D -and $magic[5] -eq 0x0A -and $magic[6] -eq 0x1A -and $magic[7] -eq 0x0A) {
                $extension = '.png'
            }
            elseif ($magic[0] -eq 0xFF -and $magic[1] -eq 0xD8 -and $magic[2] -eq 0xFF) {
                $extension = '.jpg'
            }
            elseif ($magic[0] -eq 0x47 -and $magic[1] -eq 0x49 -and $magic[2] -eq 0x46 -and $magic[3] -eq 0x38 -and
                ($magic[4] -eq 0x37 -or $magic[4] -eq 0x39) -and $magic[5] -eq 0x61) {
                $extension = '.gif'
            }
            if (-not $extension) {
                throw "The downloaded file is not a PNG, JPEG or GIF image (unrecognized file signature)."
            }

            $finalFile = [System.IO.Path]::ChangeExtension($tempFile, $extension)
            Move-Item -LiteralPath $tempFile -Destination $finalFile -Force -ErrorAction Stop
            $tempFile = $null

            $brandingParams[$image.ParamName] = $finalFile
            Write-RjRbLog -Message "Branding: using the custom $($image.Kind) image from '$url' ($([math]::Round($fileItem.Length / 1KB, 1)) KB, $extension)" -Verbose
        }
        catch {
            Write-RjRbLog -Message "WARNING: Branding: the custom $($image.Kind) image from '$url' could not be used - the default image is used instead. $($_.Exception.Message)" -Verbose
            # Write-Warning (not Write-Output): inside this value-returning function, Write-Output
            # would pollute the returned hashtable and break splatting at the call sites.
            Write-Warning -Message "The custom $($image.Kind) image could not be downloaded or is not a usable image - the report email uses the default $($image.Kind) image instead."
            if ($tempFile -and (Test-Path -LiteralPath $tempFile)) {
                Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $brandingParams
}

# Backwards-compatible alias: the original public name was Send-RjReportEmail.
# The function was renamed to Send-RjRbReportEmail for naming consistency (RjRb
# prefix); keep the old name working for existing runbooks.
New-Alias -Name Send-RjReportEmail -Value Send-RjRbReportEmail