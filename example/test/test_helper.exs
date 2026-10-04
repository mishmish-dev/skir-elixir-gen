ExUnit.start()

# Include the local runtime dependency when Mix instruments the example.
if Process.whereis(:cover_server), do: :cover.compile_beam_directory(:code.lib_dir(:skir, :ebin))
