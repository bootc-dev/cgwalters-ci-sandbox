# Checkpoint evidence is newline-delimited because Nu's `save` does not add a
# record separator for scalar input.
export def write-checkpoint-marker [path: string, marker: string] {
    $"($marker)\n" | save --force $path
}

export def append-checkpoint-marker [path: string, marker: string] {
    $"($marker)\n" | save --append $path
}

export def checkpoint-markers [path: string] {
    open --raw $path | lines
}

export def checkpoint-marker-present [path: string, marker: string] {
    $marker in (checkpoint-markers $path)
}
