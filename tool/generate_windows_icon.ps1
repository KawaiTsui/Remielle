param(
  [Parameter(Mandatory = $true)]
  [string]$Source,

  [Parameter(Mandatory = $true)]
  [string]$Output
)

Add-Type -AssemblyName System.Drawing

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$sourceImage = [System.Drawing.Image]::FromFile($Source)
$pngStreams = [System.Collections.Generic.List[System.IO.MemoryStream]]::new()

try {
  $cropSize = [Math]::Min($sourceImage.Width, $sourceImage.Height)
  $sourceX = [int](($sourceImage.Width - $cropSize) / 2)
  $sourceY = [int](($sourceImage.Height - $cropSize) / 2)

  foreach ($size in $sizes) {
    $bitmap = [System.Drawing.Bitmap]::new(
      $size,
      $size,
      [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    )
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
      $graphics.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
      $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
      $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
      $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
      $graphics.DrawImage(
        $sourceImage,
        [System.Drawing.Rectangle]::new(0, 0, $size, $size),
        [System.Drawing.Rectangle]::new($sourceX, $sourceY, $cropSize, $cropSize),
        [System.Drawing.GraphicsUnit]::Pixel
      )

      $stream = [System.IO.MemoryStream]::new()
      $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
      $pngStreams.Add($stream)
    } finally {
      $graphics.Dispose()
      $bitmap.Dispose()
    }
  }

  $outputDirectory = [System.IO.Path]::GetDirectoryName(
    [System.IO.Path]::GetFullPath($Output)
  )
  [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

  $fileStream = [System.IO.File]::Create($Output)
  $writer = [System.IO.BinaryWriter]::new($fileStream)
  try {
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]$pngStreams.Count)

    $offset = 6 + (16 * $pngStreams.Count)
    for ($index = 0; $index -lt $pngStreams.Count; $index++) {
      $size = $sizes[$index]
      $stream = $pngStreams[$index]
      $writer.Write([byte]($(if ($size -eq 256) { 0 } else { $size })))
      $writer.Write([byte]($(if ($size -eq 256) { 0 } else { $size })))
      $writer.Write([byte]0)
      $writer.Write([byte]0)
      $writer.Write([uint16]1)
      $writer.Write([uint16]32)
      $writer.Write([uint32]$stream.Length)
      $writer.Write([uint32]$offset)
      $offset += [int]$stream.Length
    }

    foreach ($stream in $pngStreams) {
      $writer.Write($stream.ToArray())
    }
  } finally {
    $writer.Dispose()
    $fileStream.Dispose()
  }
} finally {
  foreach ($stream in $pngStreams) {
    $stream.Dispose()
  }
  $sourceImage.Dispose()
}
