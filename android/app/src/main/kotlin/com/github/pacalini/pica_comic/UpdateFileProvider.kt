package com.github.pacalini.pica_comic

import androidx.core.content.FileProvider

/// Shares downloaded updates with the system installer. A class of its own,
/// so it does not clash with the file providers that plugins declare.
class UpdateFileProvider : FileProvider()
