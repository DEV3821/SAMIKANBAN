$ErrorActionPreference='Stop';. (Join-Path $PSScriptRoot '..\meeting_pack.ps1')
$source=Join-Path $PSScriptRoot '..\data\projects.example.json';$revision=Get-MeetingPackRevision $source
$body=@{format='md';mode='preview';scope='portfolio';projectIds=@();revision=$revision}|ConvertTo-Json
$md=Invoke-MeetingPackExport $body $source $source (Split-Path (Split-Path $source)) $false
if($md.ContentType-notlike'text/markdown*'-or$md.Bytes.Length-lt100){throw'Markdown export invalid'}
$body=@{format='xlsx';mode='preview';scope='portfolio';projectIds=@();revision=$revision}|ConvertTo-Json
$xlsx=Invoke-MeetingPackExport $body $source $source (Split-Path (Split-Path $source)) $false
if($xlsx.Bytes[0]-ne0x50-or$xlsx.Bytes[1]-ne0x4b){throw'XLSX package invalid'}
$ms=[IO.MemoryStream]::new($xlsx.Bytes);$zip=[IO.Compression.ZipArchive]::new($ms,[IO.Compression.ZipArchiveMode]::Read)
try{$names=@($zip.Entries.FullName);foreach($required in @('xl/tables/table1.xml','xl/worksheets/sheet1.xml','xl/drawings/drawing1.xml','xl/media/sami-mark.png','docProps/custom.xml')){if($names-notcontains$required){throw"Missing XLSX part: $required"}};$sheet=$zip.GetEntry('xl/worksheets/sheet1.xml');$reader=[IO.StreamReader]::new($sheet.Open());try{$xml=$reader.ReadToEnd()}finally{$reader.Dispose()};if($xml-notmatch'topLeftCell="C4"'-or$xml-notmatch'<tablePart'){throw'XLSX freeze/table invalid'}}finally{$zip.Dispose();$ms.Dispose()}
'MEETING_PACK_TESTS_OK'
