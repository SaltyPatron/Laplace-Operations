# SHA-256 manifest of a tree, for the copy-off (copyoff.ps1): one line per file (relative path, size, sha256), sorted by
# path, between a header and a totals line, in the format hart-server's verify.sh reads. The hashing is compiled C# with
# a bounded worker pool (8 threads); rows stream to OUT.part as they are hashed, and the sorted manifest replaces OUT at
# the end.
#   pwsh -File backup\hash-manifest.ps1 -Root D:\X -Out X.tsv [-Xd dir,name,...] [-Xf glob,...]
# -Xd: an absolute directory (skipped with everything under it) or a directory name (skipped wherever it occurs).
# -Xf: a file-name glob. Junctions, symbolic links and reparse-point files are skipped, as robocopy /XJ does.
param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Out, [string[]]$Xd = @(), [string[]]$Xf = @(), [int]$Threads = 8)
$ErrorActionPreference = 'Stop'
# pwsh -File passes a list as one comma-joined string
$Xd = @($Xd | ForEach-Object { $_ -split ',' } | Where-Object { $_ }); $Xf = @($Xf | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
Add-Type -TypeDefinition @'
using System; using System.Collections.Concurrent; using System.Collections.Generic; using System.IO; using System.Linq;
using System.Management.Automation; using System.Security.Cryptography; using System.Threading.Tasks;
public static class CopyoffHasher {
    public static List<(string Path, long Size)> Walk(string root, string[] xdAbs, string[] xdNames, WildcardPattern[] xf) {
        var files = new List<(string, long)>(); var stack = new Stack<DirectoryInfo>(); stack.Push(new DirectoryInfo(root));
        while (stack.Count > 0) {
            var d = stack.Pop(); FileSystemInfo[] entries;
            entries = d.GetFileSystemInfos();
            foreach (var e in entries) {
                if ((e.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                if (e is DirectoryInfo sub) {
                    if (xdNames.Contains(sub.Name, StringComparer.OrdinalIgnoreCase)) continue;
                    if (xdAbs.Any(x => sub.FullName.Equals(x, StringComparison.OrdinalIgnoreCase) || sub.FullName.StartsWith(x + "\\", StringComparison.OrdinalIgnoreCase))) continue;
                    stack.Push(sub);
                } else if (e is FileInfo f) {
                    if (xf.Any(p => p.IsMatch(f.Name))) continue;
                    files.Add((f.FullName, f.Length));
                }
            }
        }
        return files;
    }
    public static List<string> Hash(string root, List<(string Path, long Size)> files, string part, int threads) {
        var rows = new ConcurrentBag<string>(); var gate = new object(); int done = 0; var t0 = DateTime.UtcNow;
        using var pf = new StreamWriter(part, false, new System.Text.UTF8Encoding(false)) { NewLine = "\n" };
        Parallel.ForEach(files, new ParallelOptions { MaxDegreeOfParallelism = threads }, f => {
            string hex; var before = new FileInfo(f.Path); var modified = before.LastWriteTimeUtc;
            try { using var s = new FileStream(f.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 20);
                  hex = Convert.ToHexString(SHA256.HashData(s)).ToLowerInvariant(); }
            catch (Exception e) { throw new IOException($"Cannot hash {f.Path}", e); }
            var after = new FileInfo(f.Path);
            if (after.Length != f.Size || after.LastWriteTimeUtc != modified) throw new IOException($"Changed while hashing: {f.Path}");
            var row = $"{Path.GetRelativePath(root, f.Path)}\t{f.Size}\t{hex}"; rows.Add(row);
            lock (gate) { pf.WriteLine(row); if (++done % 20000 == 0) { pf.Flush(); Console.WriteLine($"  {done:N0}/{files.Count:N0}  {(DateTime.UtcNow - t0).TotalSeconds:F0}s"); } }
        });
        var sorted = rows.ToList(); sorted.Sort((a, b) => string.CompareOrdinal(a.Substring(0, a.IndexOf('\t')), b.Substring(0, b.IndexOf('\t'))));
        return sorted;
    }
}
'@
$root = [IO.Path]::GetFullPath($Root)
$xdAbs = @($Xd | Where-Object { [IO.Path]::IsPathRooted($_) } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
$xdNames = @($Xd | Where-Object { $_ -and -not [IO.Path]::IsPathRooted($_) })
$xfPat = @($Xf | Where-Object { $_ } | ForEach-Object { [Management.Automation.WildcardPattern]::new($_, 'IgnoreCase') })
$t0 = Get-Date
$files = [CopyoffHasher]::Walk($root, [string[]]$xdAbs, [string[]]$xdNames, [Management.Automation.WildcardPattern[]]$xfPat)
'  {0:N0} files, {1:N1} GB to hash' -f $files.Count, (($files | ForEach-Object Item2 | Measure-Object -Sum).Sum / 1GB)
$rows = [CopyoffHasher]::Hash($root, $files, "$Out.part", $Threads)
$bytes = [int64]0; foreach ($r in $rows) { $bytes += [int64]($r.Split("`t")[1]) }
$w = [IO.StreamWriter]::new($Out, $false, [Text.UTF8Encoding]::new($false)); $w.NewLine = "`r`n"
try { $w.WriteLine("# path`tsize`tsha256   source=$root"); foreach ($r in $rows) { $w.WriteLine($r) }; $w.WriteLine("# total files=$($rows.Count) bytes=$bytes") } finally { $w.Dispose() }
Remove-Item "$Out.part"
'  done in {0:N0}s' -f ((Get-Date) - $t0).TotalSeconds
