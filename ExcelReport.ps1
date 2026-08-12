# Windows PowerShell 5.1 does not load System.IO.Compression by default; a no-op on PowerShell 7+.
if ($PSVersionTable.PSVersion.Major -le 5) {
    Add-Type -AssemblyName System.IO.Compression
}

function Export-RjRbXlsx {
    <#
        .SYNOPSIS
        Exports objects to an Excel workbook (.xlsx) without external module dependencies.

        .DESCRIPTION
        Writes one or more tables of PSCustomObjects as a native Excel workbook using only
        .NET (System.IO.Compression). Each worksheet gets a styled Excel table (navy header,
        zebra rows that follow re-sorting, filter dropdowns), a frozen header row, calculated
        column widths and an automatic print setup (orientation from content width, header
        row repeated per page).

        Cell values keep their type: .NET numbers become Excel numbers, DateTime/DateTimeOffset
        values and ISO-8601 strings become real Excel dates (localized by the client; dates
        before 1900 stay text since Excel cannot render them), http/https URLs
        become clickable hyperlinks (disable with -NoHyperlink). All other strings stay text -
        values like serial numbers or IMEIs are never converted to numbers, and formula
        injection is not possible.

        .PARAMETER InputObject
        The rows to export (array of objects; also accepted via pipeline). Column order
        follows the property order of the first object.

        .PARAMETER Path
        Full path of the .xlsx file to create. An existing file is overwritten.

        .PARAMETER WorksheetName
        Name of the single worksheet (default: "Report").

        .PARAMETER Worksheets
        Ordered dictionary of worksheet name -> rows for a workbook with multiple worksheets,
        e.g. ([ordered]@{ 'Summary' = $summary; 'Details' = $details }).

        .PARAMETER NoHyperlink
        Do not convert http/https URL strings into clickable hyperlinks.

        .PARAMETER HighlightRules
        Optional conditional formatting rules for status columns. Array of hashtables (or
        objects) with Column (header name), Value (exact cell text, case-insensitive) and Color
        ('Green', 'Red' or 'Yellow' - the classic Excel highlight presets), e.g.
        @( @{ Column = 'InIntune'; Value = 'yes'; Color = 'Green' },
           @{ Column = 'InIntune'; Value = 'no';  Color = 'Red' } )
        Rules are applied on every worksheet that contains the named column.

        .PARAMETER CoverSheet
        Optional ordered dictionary rendered as an "Info" cover worksheet (first tab):
        a 'Title' key becomes the heading, all other keys become label/value rows, e.g.
        ([ordered]@{ Title = 'Device Report'; Tenant = 'contoso'; Generated = '2026-07-16 08:00 UTC' })

        .PARAMETER HyperlinkText
        Optional dictionary of column name -> display text for hyperlink cells, e.g.
        @{ Portal = 'Open in Intune' }. The cell shows the friendly text, the link target
        stays the full URL. Columns without a mapping keep showing the URL.

        .PARAMETER HideGridLines
        Hide the worksheet grid lines outside the table. Off by default (grid lines help
        readability); the cover sheet always hides them.

        .PARAMETER UseThousandsSeparator
        Format numeric cells with a thousands separator (#,##0 for integers, #,##0.00 for
        decimals, localized by Excel). Off by default.

        .PARAMETER DataBarColumns
        Optional list of numeric column names that get an in-cell data bar (orange,
        min-to-max gradient), e.g. @('DeviceCount'). Lets outliers stand out at a glance
        while the cells stay sortable and filterable. Columns that do not exist on a
        worksheet are skipped.

        .EXAMPLE
        PS C:\> $devices | Export-RjRbXlsx -Path report.xlsx -WorksheetName 'Devices'

        .EXAMPLE
        PS C:\> Export-RjRbXlsx -Worksheets ([ordered]@{ Summary = $sum; Details = $det }) -Path report.xlsx

        .EXAMPLE
        PS C:\> Export-RjRbXlsx -Worksheets ([ordered]@{ Devices = $devices }) -Path report.xlsx `
                    -CoverSheet ([ordered]@{ Title = 'Device Report'; Tenant = $tenantName }) `
                    -HighlightRules @( @{ Column = 'Compliant'; Value = 'no'; Color = 'Red' } ) `
                    -DataBarColumns @('DeviceCount')
    #>
    [CmdletBinding(DefaultParameterSetName = 'SingleSheet')]
    param(
        [Parameter(ParameterSetName = 'SingleSheet', ValueFromPipeline = $true)]
        [object[]]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(ParameterSetName = 'SingleSheet')]
        [string]$WorksheetName = 'Report',

        [Parameter(Mandatory = $true, ParameterSetName = 'MultiSheet')]
        [System.Collections.IDictionary]$Worksheets,

        [switch]$NoHyperlink,

        [object[]]$HighlightRules,

        [System.Collections.IDictionary]$CoverSheet,

        [System.Collections.IDictionary]$HyperlinkText,

        [switch]$HideGridLines,

        [switch]$UseThousandsSeparator,

        [object[]]$DataBarColumns
    )

    begin {
        $pipelineRows = [System.Collections.Generic.List[object]]::new()

        $invariant = [System.Globalization.CultureInfo]::InvariantCulture

        function ConvertTo-XlsxXmlText {
            param([string]$Text)
            # Strip control characters that are invalid in XML 1.0 (keep tab/LF/CR), then escape
            $sb = [System.Text.StringBuilder]::new($Text.Length)
            foreach ($ch in $Text.ToCharArray()) {
                $code = [int]$ch
                if ($code -lt 32 -and $code -ne 9 -and $code -ne 10 -and $code -ne 13) { continue }
                switch ($ch) {
                    '&' { [void]$sb.Append('&amp;') }
                    '<' { [void]$sb.Append('&lt;') }
                    '>' { [void]$sb.Append('&gt;') }
                    '"' { [void]$sb.Append('&quot;') }
                    default { [void]$sb.Append($ch) }
                }
            }
            $sb.ToString()
        }

        function ConvertTo-XlsxColumnName {
            param([int]$Index) # 1-based
            $name = ''
            while ($Index -gt 0) {
                $Index--
                $name = [char](65 + ($Index % 26)) + $name
                $Index = [int][math]::Floor($Index / 26)
            }
            $name
        }

        function Get-XlsxSheetName {
            param([string]$Name, [int]$Number, [System.Collections.Generic.HashSet[string]]$Used)
            $clean = ($Name -replace '[\[\]:*?/\\]', ' ').Trim().Trim("'")
            if (-not $clean) { $clean = "Sheet$Number" }
            if ($clean.Length -gt 31) { $clean = $clean.Substring(0, 31).Trim() }
            $candidate = $clean
            $suffix = 2
            while (-not $Used.Add($candidate)) {
                $tail = "_$suffix"
                $candidate = $clean.Substring(0, [math]::Min($clean.Length, 31 - $tail.Length)) + $tail
                $suffix++
            }
            $candidate
        }

        function Find-XlsxColumnIndex {
            param([string[]]$Headers, [string]$Name) # returns -1 when not found
            for ($i = 0; $i -lt $Headers.Count; $i++) {
                if ($Headers[$i] -eq $Name) { return $i }
            }
            return -1
        }

        function New-XlsxDateCell {
            param([datetime]$Value, [string]$CellRef, [System.Globalization.CultureInfo]$Invariant)
            # Excel cannot render date serials below 1 (before 1900; DateTime.MinValue maps
            # to serial 0 which Excel shows as the bogus "1/0/1900") - fall back to text
            $oaDate = $Value.ToOADate()
            if ($oaDate -lt 1) {
                $text = if ($Value.TimeOfDay -eq [timespan]::Zero) { $Value.ToString('yyyy-MM-dd', $Invariant) }
                else { $Value.ToString('yyyy-MM-dd HH:mm:ss', $Invariant) }
                [pscustomobject]@{ Xml = "<c r=""$CellRef"" t=""inlineStr""><is><t>$text</t></is></c>"; Length = $text.Length }
            }
            else {
                $style = if ($Value.TimeOfDay -eq [timespan]::Zero) { 1 } else { 2 }
                [pscustomobject]@{ Xml = "<c r=""$CellRef"" s=""$style""><v>$($oaDate.ToString($Invariant))</v></c>"; Length = 17 }
            }
        }

        function Get-XlsxRuleProperty {
            param($Rule, [string]$Name) # tolerates hashtables and objects with missing members
            if ($Rule -is [System.Collections.IDictionary]) { return $Rule[$Name] }
            $prop = $Rule.PSObject.Properties[$Name]
            if ($prop) { return $prop.Value }
            return $null
        }
    }

    process {
        if ($PSCmdlet.ParameterSetName -eq 'SingleSheet' -and $null -ne $InputObject) {
            foreach ($item in $InputObject) { $pipelineRows.Add($item) }
        }
    }

    end {
        # Normalize both parameter sets into an ordered list of (Name, Rows); dictionaries become objects
        $normalizeRows = {
            param($Rows)
            @($Rows) | Where-Object { $null -ne $_ } | ForEach-Object {
                if ($_ -is [System.Collections.IDictionary]) { [pscustomobject]$_ } else { $_ }
            }
        }
        $sheetDefs = [System.Collections.Generic.List[object]]::new()
        if ($PSCmdlet.ParameterSetName -eq 'MultiSheet') {
            foreach ($key in $Worksheets.Keys) {
                $sheetDefs.Add([pscustomobject]@{ Name = [string]$key; Rows = @(& $normalizeRows $Worksheets[$key]); IsCover = $false })
            }
            if ($sheetDefs.Count -eq 0) { throw "Export-RjRbXlsx: -Worksheets must contain at least one entry." }
        }
        else {
            $sheetDefs.Add([pscustomobject]@{ Name = $WorksheetName; Rows = @(& $normalizeRows $pipelineRows); IsCover = $false })
        }
        if ($CoverSheet) {
            $sheetDefs.Insert(0, [pscustomobject]@{ Name = 'Info'; Rows = @(); IsCover = $true })
        }

        $usedSheetNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $xmlDecl = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        $mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
        $relNs = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
        $pkgRelNs = 'http://schemas.openxmlformats.org/package/2006/relationships'
        $maxDataRows = 1048575 # xlsx row limit (1,048,576) minus header row
        $isoDateRegex = [regex]'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'

        # Resolve PSProvider-relative paths; [System.IO.File] would otherwise resolve
        # against the process working directory instead of the PowerShell location.
        $resolvedPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Path)
        if (Test-Path -LiteralPath $resolvedPath) { Remove-Item -LiteralPath $resolvedPath -Force }
        $fileStream = [System.IO.File]::Open($resolvedPath, [System.IO.FileMode]::CreateNew)
        try {
            $zip = [System.IO.Compression.ZipArchive]::new($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                $writeEntry = {
                    param([string]$EntryName, [string]$Content)
                    $entry = $zip.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
                    $writer = [System.IO.StreamWriter]::new($entry.Open(), $utf8NoBom)
                    try { $writer.Write($Content) } finally { $writer.Dispose() }
                }

                #region Static package parts
                $contentTypes = [System.Text.StringBuilder]::new()
                [void]$contentTypes.Append("$xmlDecl<Types xmlns=""http://schemas.openxmlformats.org/package/2006/content-types"">")
                [void]$contentTypes.Append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
                [void]$contentTypes.Append('<Default Extension="xml" ContentType="application/xml"/>')
                [void]$contentTypes.Append('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
                [void]$contentTypes.Append('<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')
                for ($s = 1; $s -le $sheetDefs.Count; $s++) {
                    [void]$contentTypes.Append("<Override PartName=""/xl/worksheets/sheet$s.xml"" ContentType=""application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml""/>")
                }
                # table overrides are appended while writing the sheets (empty sheets have no table)

                & $writeEntry '_rels/.rels' ("$xmlDecl<Relationships xmlns=""$pkgRelNs"">" +
                    "<Relationship Id=""rId1"" Type=""$relNs/officeDocument"" Target=""xl/workbook.xml""/>" +
                    '</Relationships>')

                # Workbook + workbook relationships
                $workbook = [System.Text.StringBuilder]::new()
                [void]$workbook.Append("$xmlDecl<workbook xmlns=""$mainNs"" xmlns:r=""$relNs""><sheets>")
                $workbookRels = [System.Text.StringBuilder]::new()
                [void]$workbookRels.Append("$xmlDecl<Relationships xmlns=""$pkgRelNs"">")
                $sheetNames = @()
                for ($s = 1; $s -le $sheetDefs.Count; $s++) {
                    $sheetName = Get-XlsxSheetName -Name $sheetDefs[$s - 1].Name -Number $s -Used $usedSheetNames
                    $sheetNames += $sheetName
                    [void]$workbook.Append("<sheet name=""$(ConvertTo-XlsxXmlText $sheetName)"" sheetId=""$s"" r:id=""rId$s""/>")
                    [void]$workbookRels.Append("<Relationship Id=""rId$s"" Type=""$relNs/worksheet"" Target=""worksheets/sheet$s.xml""/>")
                }
                [void]$workbook.Append('</sheets>')
                # Repeat the header row on every printed page (skipped for the cover sheet)
                $printTitles = ''
                for ($s = 1; $s -le $sheetDefs.Count; $s++) {
                    if ($sheetDefs[$s - 1].IsCover) { continue }
                    $quotedName = ConvertTo-XlsxXmlText ($sheetNames[$s - 1] -replace "'", "''")
                    $printTitles += '<definedName name="_xlnm.Print_Titles" localSheetId="' + ($s - 1) + '">&apos;' + $quotedName + '&apos;!$1:$1</definedName>'
                }
                if ($printTitles) { [void]$workbook.Append("<definedNames>$printTitles</definedNames>") }
                [void]$workbook.Append('</workbook>')
                [void]$workbookRels.Append("<Relationship Id=""rId$($sheetDefs.Count + 1)"" Type=""$relNs/styles"" Target=""styles.xml""/>")
                [void]$workbookRels.Append('</Relationships>')
                & $writeEntry 'xl/workbook.xml' $workbook.ToString()
                & $writeEntry 'xl/_rels/workbook.xml.rels' $workbookRels.ToString()

                # Styles. Fonts: 0=default, 1=hyperlink, 2=cover title, 3=cover label.
                # cellXfs: 0=default, 1=date, 2=datetime, 3=hyperlink, 4=int grouped, 5=decimal grouped,
                #          6=cover title (orange accent border), 7=cover accent line, 8=cover label
                & $writeEntry 'xl/styles.xml' ("$xmlDecl<styleSheet xmlns=""$mainNs"">" +
                    '<fonts count="4">' +
                    '<font><sz val="12"/><name val="Calibri"/><family val="2"/></font>' +
                    '<font><u/><sz val="12"/><color rgb="FF0563C1"/><name val="Calibri"/><family val="2"/></font>' +
                    '<font><b/><sz val="18"/><color rgb="FF1B2A44"/><name val="Calibri"/><family val="2"/></font>' +
                    '<font><b/><sz val="12"/><color rgb="FF595959"/><name val="Calibri"/><family val="2"/></font>' +
                    '</fonts>' +
                    '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>' +
                    '<borders count="2">' +
                    '<border><left/><right/><top/><bottom/><diagonal/></border>' +
                    '<border><left/><right/><top/><bottom style="thick"><color rgb="FFF0871E"/></bottom><diagonal/></border>' +
                    '</borders>' +
                    '<cellStyleXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0"/></cellStyleXfs>' +
                    '<cellXfs count="9">' +
                    '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
                    '<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
                    '<xf numFmtId="22" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
                    '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="1" applyFont="1"/>' +
                    '<xf numFmtId="3" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
                    '<xf numFmtId="4" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>' +
                    '<xf numFmtId="0" fontId="2" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/>' +
                    '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyBorder="1"/>' +
                    '<xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/>' +
                    '</cellXfs>' +
                    '<cellStyles count="2"><cellStyle name="Normal" xfId="0" builtinId="0"/><cellStyle name="Hyperlink" xfId="1" builtinId="8"/></cellStyles>' +
                    # dxf 0-2 = classic Excel highlight presets green/red/yellow (used by -HighlightRules),
                    # dxf 3-5 = custom table style: navy header, zebra stripe, explicit white second stripe
                    # (white second stripe covers the grid lines inside the table; banding follows re-sorting)
                    '<dxfs count="6">' +
                    '<dxf><font><color rgb="FF006100"/></font><fill><patternFill><bgColor rgb="FFC6EFCE"/></patternFill></fill></dxf>' +
                    '<dxf><font><color rgb="FF9C0006"/></font><fill><patternFill><bgColor rgb="FFFFC7CE"/></patternFill></fill></dxf>' +
                    '<dxf><font><color rgb="FF9C6500"/></font><fill><patternFill><bgColor rgb="FFFFEB9C"/></patternFill></fill></dxf>' +
                    '<dxf><font><b/><color rgb="FFFFFFFF"/></font><fill><patternFill><bgColor rgb="FF1B2A44"/></patternFill></fill></dxf>' +
                    '<dxf><fill><patternFill><bgColor rgb="FFDEE4EE"/></patternFill></fill></dxf>' +
                    '<dxf><fill><patternFill><bgColor rgb="FFFFFFFF"/></patternFill></fill></dxf>' +
                    '</dxfs>' +
                    '<tableStyles count="1" defaultTableStyle="TableStyleMedium2" defaultPivotStyle="PivotStyleLight16">' +
                    '<tableStyle name="RjRbReport" pivot="0" count="3">' +
                    '<tableStyleElement type="headerRow" dxfId="3"/>' +
                    '<tableStyleElement type="firstRowStripe" dxfId="4"/>' +
                    '<tableStyleElement type="secondRowStripe" dxfId="5"/>' +
                    '</tableStyle></tableStyles>' +
                    '</styleSheet>')
                #endregion

                #region Worksheets
                for ($s = 1; $s -le $sheetDefs.Count; $s++) {
                    # First tab in RealmJoin orange, remaining tabs in neutral gray
                    $tabColorRgb = if ($s -eq 1) { 'FFF0871E' } else { 'FF7F7F7F' }

                    # Cover sheet: title + label/value rows, no table, no grid lines
                    if ($sheetDefs[$s - 1].IsCover) {
                        $coverTitle = if ($CoverSheet.Contains('Title')) { [string]$CoverSheet['Title'] } else { 'Report' }
                        $coverKeys = @($CoverSheet.Keys | Where-Object { [string]$_ -ne 'Title' })
                        $cover = [System.Text.StringBuilder]::new()
                        [void]$cover.Append("$xmlDecl<worksheet xmlns=""$mainNs"" xmlns:r=""$relNs"">")
                        [void]$cover.Append("<sheetPr><tabColor rgb=""$tabColorRgb""/></sheetPr>")
                        [void]$cover.Append("<dimension ref=""A1:C$($coverKeys.Count + 4)""/>")
                        [void]$cover.Append('<sheetViews><sheetView workbookViewId="0" showGridLines="0"/></sheetViews>')
                        # Narrow spacer column A indents the content away from the sheet edge
                        [void]$cover.Append('<cols><col min="1" max="1" width="3.6" customWidth="1"/><col min="2" max="2" width="26" customWidth="1"/><col min="3" max="3" width="48" customWidth="1"/></cols>')
                        [void]$cover.Append('<sheetData>')
                        # Title in row 3: navy heading with an orange accent line spanning both content columns
                        [void]$cover.Append("<row r=""3"" ht=""30"" customHeight=""1""><c r=""B3"" s=""6"" t=""inlineStr""><is><t>$(ConvertTo-XlsxXmlText $coverTitle)</t></is></c><c r=""C3"" s=""7""/></row>")
                        $coverRow = 4
                        foreach ($coverKey in $coverKeys) {
                            $coverRow++
                            $labelXml = ConvertTo-XlsxXmlText ([string]$coverKey)
                            $valueXml = ConvertTo-XlsxXmlText ([string]$CoverSheet[$coverKey])
                            [void]$cover.Append("<row r=""$coverRow"" ht=""20"" customHeight=""1""><c r=""B$coverRow"" s=""8"" t=""inlineStr""><is><t>$labelXml</t></is></c><c r=""C$coverRow"" t=""inlineStr""><is><t>$valueXml</t></is></c></row>")
                        }
                        [void]$cover.Append('</sheetData></worksheet>')
                        & $writeEntry "xl/worksheets/sheet$s.xml" $cover.ToString()
                        continue
                    }

                    $rows = @($sheetDefs[$s - 1].Rows | Where-Object { $null -ne $_ })
                    if ($rows.Count -gt $maxDataRows) {
                        throw "Export-RjRbXlsx: worksheet '$($sheetNames[$s - 1])' has $($rows.Count) rows - the xlsx limit is $maxDataRows data rows."
                    }

                    # Header names from the property order of the first object, deduplicated (table columns must be unique and non-empty)
                    $headers = @()
                    if ($rows.Count -gt 0) {
                        $seenHeaders = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        $col = 0
                        foreach ($prop in $rows[0].PSObject.Properties.Name) {
                            $col++
                            $name = if ([string]::IsNullOrWhiteSpace($prop)) { "Column$col" } else { $prop }
                            $suffix = 2
                            $candidate = $name
                            while (-not $seenHeaders.Add($candidate)) { $candidate = "${name}_$suffix"; $suffix++ }
                            $headers += $candidate
                        }
                    }

                    # Empty worksheet: single info cell, no table
                    if ($headers.Count -eq 0) {
                        & $writeEntry "xl/worksheets/sheet$s.xml" ("$xmlDecl<worksheet xmlns=""$mainNs"" xmlns:r=""$relNs"">" +
                            "<sheetPr><tabColor rgb=""$tabColorRgb""/></sheetPr>" +
                            '<dimension ref="A1:A1"/><sheetViews><sheetView workbookViewId="0"/></sheetViews>' +
                            '<sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>No data available</t></is></c></row></sheetData>' +
                            '</worksheet>')
                        continue
                    }

                    [void]$contentTypes.Append("<Override PartName=""/xl/tables/table$s.xml"" ContentType=""application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml""/>")

                    $colCount = $headers.Count
                    $propNames = @($rows[0].PSObject.Properties.Name)
                    $colNames = @(1..$colCount | ForEach-Object { ConvertTo-XlsxColumnName $_ })
                    $lastColName = $colNames[$colCount - 1]
                    $lastRow = $rows.Count + 1
                    $tableRef = "A1:$lastColName$lastRow"

                    # Pre-compute cell descriptors and column widths (widths from the first 1000 rows)
                    $widths = @($headers | ForEach-Object { $_.Length + 3 }) # + filter dropdown button
                    $cellMatrix = [System.Collections.Generic.List[object]]::new()
                    $hyperlinks = [System.Collections.Generic.List[object]]::new()
                    $rowIndex = 1
                    foreach ($row in $rows) {
                        $rowIndex++
                        $cells = [System.Collections.Generic.List[string]]::new()
                        for ($c = 1; $c -le $colCount; $c++) {
                            $propInfo = $row.PSObject.Properties[$propNames[$c - 1]]
                            $value = if ($propInfo) { $propInfo.Value } else { $null }
                            $cellRef = "$($colNames[$c - 1])$rowIndex"
                            $displayLength = 0
                            $cellXml = $null

                            if ($null -eq $value -or $value -is [System.DBNull]) {
                                $cells.Add('')
                                continue
                            }

                            # DateTimeOffset (e.g. from Graph SDK models) is treated like DateTime, normalized to UTC
                            if ($value -is [System.DateTimeOffset]) { $value = $value.UtcDateTime }

                            $typeCode = if ($value -is [string]) { [System.TypeCode]::String } else { [System.Type]::GetTypeCode($value.GetType()) }

                            if ($value -is [datetime]) {
                                $dateCell = New-XlsxDateCell -Value $value -CellRef $cellRef -Invariant $invariant
                                $cellXml = $dateCell.Xml
                                $displayLength = $dateCell.Length
                            }
                            elseif ($value -is [bool]) {
                                $cellXml = "<c r=""$cellRef"" t=""b""><v>$(if ($value) { 1 } else { 0 })</v></c>"
                                $displayLength = 5
                            }
                            elseif ($typeCode -in @(
                                    [System.TypeCode]::Byte, [System.TypeCode]::SByte, [System.TypeCode]::Int16, [System.TypeCode]::UInt16,
                                    [System.TypeCode]::Int32, [System.TypeCode]::UInt32, [System.TypeCode]::Int64, [System.TypeCode]::UInt64,
                                    [System.TypeCode]::Single, [System.TypeCode]::Double, [System.TypeCode]::Decimal)) {
                                $numText = [string]$value.ToString($invariant)
                                if ($numText -match '^(NaN|.*Infinity)$') {
                                    $escaped = ConvertTo-XlsxXmlText $numText
                                    $cellXml = "<c r=""$cellRef"" t=""inlineStr""><is><t>$escaped</t></is></c>"
                                }
                                else {
                                    $numStyle = ''
                                    if ($UseThousandsSeparator) {
                                        $isDecimalType = $typeCode -in @([System.TypeCode]::Single, [System.TypeCode]::Double, [System.TypeCode]::Decimal)
                                        $numStyle = if ($isDecimalType) { ' s="5"' } else { ' s="4"' }
                                    }
                                    $cellXml = "<c r=""$cellRef""$numStyle><v>$numText</v></c>"
                                }
                                $displayLength = $numText.Length
                            }
                            else {
                                # Everything else is rendered as text (arrays joined, objects stringified)
                                $text = if ($value -is [string]) { $value }
                                elseif ($value -is [System.Collections.IEnumerable]) { @($value | ForEach-Object { [string]$_ }) -join '; ' }
                                else { [string]$value }

                                $parsedDate = [datetime]::MinValue
                                if ($isoDateRegex.IsMatch($text) -and [datetime]::TryParse($text, $invariant,
                                        [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$parsedDate)) {
                                    # ISO-8601 strings (Graph date fields) become real, sortable Excel dates
                                    $dateCell = New-XlsxDateCell -Value $parsedDate -CellRef $cellRef -Invariant $invariant
                                    $cellXml = $dateCell.Xml
                                    $displayLength = $dateCell.Length
                                }
                                else {
                                    $escaped = ConvertTo-XlsxXmlText $text
                                    $preserve = if ($text -match '^\s|\s$') { ' xml:space="preserve"' } else { '' }
                                    $isUrl = (-not $NoHyperlink) -and $text -match '^https?://' -and
                                        [System.Uri]::IsWellFormedUriString($text, [System.UriKind]::Absolute)
                                    if ($isUrl) {
                                        # Optional friendly display text per column; the link target stays the full URL
                                        $display = $text
                                        if ($HyperlinkText -and $HyperlinkText.Contains($propNames[$c - 1]) -and $HyperlinkText[$propNames[$c - 1]]) {
                                            $display = [string]$HyperlinkText[$propNames[$c - 1]]
                                        }
                                        $escapedDisplay = ConvertTo-XlsxXmlText $display
                                        $cellXml = "<c r=""$cellRef"" s=""3"" t=""inlineStr""><is><t>$escapedDisplay</t></is></c>"
                                        $hyperlinks.Add([pscustomobject]@{ Ref = $cellRef; Url = $text })
                                        $displayLength = $display.Length
                                    }
                                    else {
                                        $cellXml = "<c r=""$cellRef"" t=""inlineStr""><is><t$preserve>$escaped</t></is></c>"
                                        $displayLength = $text.Length
                                    }
                                }
                            }

                            $cells.Add($cellXml)
                            if ($rowIndex -le 1001 -and $displayLength -gt $widths[$c - 1]) { $widths[$c - 1] = $displayLength }
                        }
                        $cellMatrix.Add($cells)
                    }

                    # Worksheet XML (schema order: sheetPr, dimension, sheetViews, cols, sheetData,
                    # conditionalFormatting, hyperlinks, pageMargins, pageSetup, tableParts)
                    $sheet = [System.Text.StringBuilder]::new()
                    [void]$sheet.Append("$xmlDecl<worksheet xmlns=""$mainNs"" xmlns:r=""$relNs"">")
                    [void]$sheet.Append("<sheetPr><tabColor rgb=""$tabColorRgb""/><pageSetUpPr fitToPage=""1""/></sheetPr>")
                    [void]$sheet.Append("<dimension ref=""$tableRef""/>")
                    $gridLinesAttr = if ($HideGridLines) { ' showGridLines="0"' } else { '' }
                    [void]$sheet.Append("<sheetViews><sheetView workbookViewId=""0""$gridLinesAttr><pane ySplit=""1"" topLeftCell=""A2"" activePane=""bottomLeft"" state=""frozen""/></sheetView></sheetViews>")
                    [void]$sheet.Append('<cols>')
                    $totalWidth = 0
                    for ($c = 1; $c -le $colCount; $c++) {
                        $width = [math]::Min([math]::Max($widths[$c - 1] + 2, 8), 60)
                        $totalWidth += $width
                        [void]$sheet.Append("<col min=""$c"" max=""$c"" width=""$width"" customWidth=""1""/>")
                    }
                    [void]$sheet.Append('</cols><sheetData>')

                    # Header row: no explicit cell style, so the table style fully controls the header look
                    [void]$sheet.Append('<row r="1">')
                    for ($c = 1; $c -le $colCount; $c++) {
                        $escaped = ConvertTo-XlsxXmlText $headers[$c - 1]
                        [void]$sheet.Append("<c r=""$($colNames[$c - 1])1"" t=""inlineStr""><is><t>$escaped</t></is></c>")
                    }
                    [void]$sheet.Append('</row>')

                    $rowIndex = 1
                    foreach ($cells in $cellMatrix) {
                        $rowIndex++
                        [void]$sheet.Append("<row r=""$rowIndex"">")
                        foreach ($cellXml in $cells) { if ($cellXml) { [void]$sheet.Append($cellXml) } }
                        [void]$sheet.Append('</row>')
                    }
                    [void]$sheet.Append('</sheetData>')

                    # Conditional formatting: status-column highlights and in-cell data bars
                    if (($HighlightRules -or $DataBarColumns) -and $rows.Count -gt 0) {
                        $dxfIds = @{ 'green' = 0; 'red' = 1; 'yellow' = 2 }
                        $priority = 1
                        foreach ($rule in @($HighlightRules)) {
                            $ruleColumn = [string](Get-XlsxRuleProperty -Rule $rule -Name 'Column')
                            $ruleColor = [string](Get-XlsxRuleProperty -Rule $rule -Name 'Color')
                            $colIndex = Find-XlsxColumnIndex -Headers $headers -Name $ruleColumn
                            if ($colIndex -lt 0) { continue }
                            $colorKey = $ruleColor.ToLowerInvariant()
                            if (-not $dxfIds.ContainsKey($colorKey)) {
                                Write-Warning "Export-RjRbXlsx: unknown highlight color '$ruleColor' - use Green, Red or Yellow. Skipping rule."
                                continue
                            }
                            $colName = $colNames[$colIndex]
                            $escapedValue = ConvertTo-XlsxXmlText ([string](Get-XlsxRuleProperty -Rule $rule -Name 'Value'))
                            [void]$sheet.Append("<conditionalFormatting sqref=""${colName}2:$colName$lastRow"">")
                            [void]$sheet.Append("<cfRule type=""cellIs"" dxfId=""$($dxfIds[$colorKey])"" priority=""$priority"" operator=""equal""><formula>&quot;$escapedValue&quot;</formula></cfRule>")
                            [void]$sheet.Append('</conditionalFormatting>')
                            $priority++
                        }
                        foreach ($dataBarColumn in @($DataBarColumns)) {
                            $colIndex = Find-XlsxColumnIndex -Headers $headers -Name ([string]$dataBarColumn)
                            if ($colIndex -lt 0) { continue }
                            $colName = $colNames[$colIndex]
                            [void]$sheet.Append("<conditionalFormatting sqref=""${colName}2:$colName$lastRow"">")
                            [void]$sheet.Append("<cfRule type=""dataBar"" priority=""$priority""><dataBar><cfvo type=""min""/><cfvo type=""max""/><color rgb=""FFF0871E""/></dataBar></cfRule>")
                            [void]$sheet.Append('</conditionalFormatting>')
                            $priority++
                        }
                    }

                    if ($hyperlinks.Count -gt 0) {
                        [void]$sheet.Append('<hyperlinks>')
                        $linkId = 1
                        foreach ($link in $hyperlinks) {
                            $linkId++
                            [void]$sheet.Append("<hyperlink ref=""$($link.Ref)"" r:id=""rId$linkId""/>")
                        }
                        [void]$sheet.Append('</hyperlinks>')
                    }
                    # Print setup: orientation derived from content width, scale to one page wide
                    $orientation = if ($totalWidth -gt 110) { 'landscape' } else { 'portrait' }
                    [void]$sheet.Append('<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>')
                    [void]$sheet.Append("<pageSetup orientation=""$orientation"" fitToWidth=""1"" fitToHeight=""0""/>")
                    [void]$sheet.Append('<tableParts count="1"><tablePart r:id="rId1"/></tableParts>')
                    [void]$sheet.Append('</worksheet>')
                    & $writeEntry "xl/worksheets/sheet$s.xml" $sheet.ToString()

                    # Table part: filter dropdowns; header and banding come from the custom RjRbReport style
                    $table = [System.Text.StringBuilder]::new()
                    [void]$table.Append("$xmlDecl<table xmlns=""$mainNs"" id=""$s"" name=""Table$s"" displayName=""Table$s"" ref=""$tableRef"" headerRowCount=""1"">")
                    [void]$table.Append("<autoFilter ref=""$tableRef""/><tableColumns count=""$colCount"">")
                    for ($c = 1; $c -le $colCount; $c++) {
                        [void]$table.Append("<tableColumn id=""$c"" name=""$(ConvertTo-XlsxXmlText $headers[$c - 1])""/>")
                    }
                    [void]$table.Append('</tableColumns><tableStyleInfo name="RjRbReport" showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/></table>')
                    & $writeEntry "xl/tables/table$s.xml" $table.ToString()

                    # Sheet relationships: rId1 = table, rId2+ = external hyperlink targets
                    $sheetRels = [System.Text.StringBuilder]::new()
                    [void]$sheetRels.Append("$xmlDecl<Relationships xmlns=""$pkgRelNs"">")
                    [void]$sheetRels.Append("<Relationship Id=""rId1"" Type=""$relNs/table"" Target=""../tables/table$s.xml""/>")
                    $linkId = 1
                    foreach ($link in $hyperlinks) {
                        $linkId++
                        [void]$sheetRels.Append("<Relationship Id=""rId$linkId"" Type=""$relNs/hyperlink"" Target=""$(ConvertTo-XlsxXmlText $link.Url)"" TargetMode=""External""/>")
                    }
                    [void]$sheetRels.Append('</Relationships>')
                    & $writeEntry "xl/worksheets/_rels/sheet$s.xml.rels" $sheetRels.ToString()
                }
                #endregion

                [void]$contentTypes.Append('</Types>')
                & $writeEntry '[Content_Types].xml' $contentTypes.ToString()
            }
            finally {
                $zip.Dispose()
            }
        }
        finally {
            $fileStream.Dispose()
        }

        Write-Verbose "Export-RjRbXlsx: wrote $($sheetDefs.Count) worksheet(s) to $Path"
    }
}
