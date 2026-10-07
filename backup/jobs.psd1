# The copy-off of HART-DESKTOP's drives to hart-server (copyoff.ps1, run by run.ps1 under the scheduled task setup.ps1
# backup declares): data, code, repositories and media only; installs, dev tools and games are reinstalled.
#
# A set is one pass: its jobs, the inbox their relative destinations are under, and its own directory under
# LAPLACE_BACKUP_LOGS for manifests, robocopy logs and patches ('' is the directory itself). A job: n name, s source,
# d destination (relative to the set's inbox, or a full UNC path), xd robocopy /XD (an absolute directory, or a name
# skipped wherever it occurs), xf robocopy /XF (file globs), man where its manifest is copied (default <inbox>\_manifest),
# manifestOnly (hashed, never copied). Patches: the uncommitted edits in LAPLACE_DEPSRC's checkouts are kept as patches.
# Models-* jobs are on hold (2026-10-07, the user: "don't touch the models"): they run only with -Models.
#
# Mounts: the share each destination is on, as hart-server mounts it, for the room guard (df and du over SSH).
@{
    Mounts = @{ vault = '/vault'; archive = '/archive'; backup = '/backup'; inbox = '/vault/Inbox' }
    Sets   = @(
        @{
            Name = 'D'; Logs = ''; Inbox = '\\hart-server\inbox\HART-DESKTOP-D'; Patches = $true
            Jobs = @(
                @{ n = 'Repositories';       s = 'D:\Repositories';      d = 'Repositories' }
                @{ n = 'Media';              s = 'D:\Media';             d = 'Media' }
                @{ n = 'ROMS';               s = 'D:\ROMS';              d = 'ROMS' }
                @{ n = 'Logs';               s = 'D:\Logs';              d = 'Logs'; xd = @('D:\Logs\copyoff') }
                @{ n = 'test_data';          s = 'D:\test_data';         d = 'test_data' }
                @{ n = 'Data-TreeSitter';    s = 'D:\Data\TreeSitter';   d = 'Data\TreeSitter' }
                @{ n = 'Data-Archive';       s = 'D:\Data\Archive';      d = 'Data\Archive' }
                @{ n = 'Data-Kaggle';        s = 'D:\Data\Kaggle';       d = 'Data\Kaggle' }
                @{ n = 'Data-ArXiv';         s = 'D:\Data\ArXiv';        d = 'Data\ArXiv' }
                @{ n = 'Data-Output';        s = 'D:\Data\Output';       d = 'Data\Output' }
                @{ n = 'Data-Laplace';       s = 'D:\Data\Laplace';      d = 'Data\Laplace'; xd = @('D:\Data\Laplace\pgdata') }
                @{ n = 'Temp-claude';        s = 'D:\Temp\claude';       d = 'Temp\claude'
                   xd = @('D:\Temp\claude\C--Users-ahart\579312a5-642d-44d8-866a-491b508dc5ef\scratchpad\det', 'D:\Temp\claude\C--Users-ahart\579312a5-642d-44d8-866a-491b508dc5ef\scratchpad\mkltest',
                          'D:\Temp\claude\C--Users-ahart\579312a5-642d-44d8-866a-491b508dc5ef\scratchpad\runtime-check', 'D:\Temp\claude\C--Users-ahart\52aa107c-7b4b-4fbb-b0bf-32c6607713ba\scratchpad\native-main',
                          '.git', 'build', 'node_modules')
                   xf = @('*.dll', '*.obj', '*.o', '*.exe', '*.pdb', '*.lib', '*.pack', '*.idx') }
                @{ n = 'Temp-oni-decompile'; s = 'D:\Temp\oni-decompile'; d = 'Temp\oni-decompile' }
                @{ n = 'Temp-oni-disease';   s = 'D:\Temp\oni-disease';  d = 'Temp\oni-disease' }
                @{ n = 'xClaude-Trash';      s = 'D:\xClaude-Trash';     d = '\\hart-server\vault\AI_Sabotage\022\xClaude-Trash'; man = '\\hart-server\vault\AI_Sabotage\022\_manifest' }
                @{ n = 'Downloads';          s = 'D:\Downloads';         d = '\\hart-server\backup\HART-DESKTOP-Downloads'; man = '\\hart-server\backup\HART-DESKTOP-Downloads\_manifest' }
                @{ n = 'Data-Ingest';        s = 'D:\Data\Ingest';       d = 'Data\Ingest'; manifestOnly = $true }
                @{ n = 'Models-Active';      s = 'D:\Models\Active';     d = 'Models\Active' }
                @{ n = 'Models-laplace-gen'; s = 'D:\Models\laplace-gen'; d = 'Models\laplace-gen' }
                @{ n = 'Models-tiny-codes';  s = 'D:\Models\hub\datasets--nampdn-ai--tiny-codes'; d = 'Models\hub\datasets--nampdn-ai--tiny-codes' }
                @{ n = 'Models-FLUX.2-dev';  s = 'D:\Models\hub\xmodels--black-forest-labs--FLUX.2-dev'; d = 'Models\hub\xmodels--black-forest-labs--FLUX.2-dev' }
                @{ n = 'Models-DeepSeek-V3.2'; s = 'D:\Models\hub\zDeepSeek-V3.2-Speciale'; d = '\\hart-server\archive\Models\hub\zDeepSeek-V3.2-Speciale'; man = '\\hart-server\archive\Models\_manifest' }
                @{ n = 'Models-Llama-4-Maverick'; s = 'D:\Models\hub\ymodels--meta-llama--Llama-4-Maverick-17B-128E'; d = 'Models\hub\ymodels--meta-llama--Llama-4-Maverick-17B-128E' }
                @{ n = 'Models-Qwen3-Coder-480B'; s = 'D:\Models\hub\wQwen3-Coder-480B-A35B-Instruct'; d = '\\hart-server\backup\Models\hub\wQwen3-Coder-480B-A35B-Instruct'; man = '\\hart-server\backup\Models\_manifest' }
            )
        }
        @{
            Name = 'C'; Logs = 'C'; Inbox = '\\hart-server\inbox\HART-DESKTOP-C'; Patches = $false
            Jobs = @(
                @{ n = 'C-source';           s = 'C:\Users\ahart\source'; d = 'Users\ahart\source' }
            )
        }
    )
}
