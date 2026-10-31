from pathlib import Path
import subprocess
root=Path(r'E:/Repositories/Laplace')
mono=root/'Laplace'
def change(path, old, new, count=None):
 p=root/path
 data=p.read_bytes(); a=old.encode(); b=new.encode()
 if a not in data:
  a=a.replace(b'\n',b'\r\n'); b=b.replace(b'\n',b'\r\n')
 assert a in data, (path,old[:90])
 if count is not None: assert data.count(a)==count,(path,data.count(a))
 p.write_bytes(data.replace(a,b))
for p in (mono/'app').rglob('*.cs'):
 if any(part in ('bin','obj') for part in p.parts): continue
 data=p.read_bytes()
 if b'1_112_064' in data: p.write_bytes(data.replace(b'1_112_064',b'1_114_112'))
 if b'Directory.Exists(Path.Combine(dir.FullName, "docs"))' in data:
  p.write_bytes(p.read_bytes().replace(b'Directory.Exists(Path.Combine(dir.FullName, "docs"))',b'Directory.Exists(Path.Combine(dir.FullName, "engine"))'))
change('Laplace/app/Laplace.Core/Core/UnicodeSeed.cs','if (snapshot.Count != UnicodeSeed.CodepointCount)','int count = snapshot.Count;\n        if (count != UnicodeSeed.CodepointCount)',1)
change('Laplace/app/Laplace.Core/Core/UnicodeSeed.cs','{snapshot.Count} records;','{count} records;',1)
# A provider role must retain the shared Native content height. Undo the bounded
# byte override introduced during this integration; Native's word floor is 2.
original=subprocess.run(['git','-C',str(mono),'show','2aca27d^:engine/core/src/modality_witness.c'],capture_output=True,check=True).stdout
(mono/'engine/core/src/modality_witness.c').write_bytes(original)
change('Laplace/engine/core/tests/test_image_decomposer.cpp','EXPECT_EQ(num.tier, LAPLACE_IMAGE_TIER_NUMBER);\n        EXPECT_EQ(hash128_compare','EXPECT_EQ(num.tier, 2); // The shared Native text composition retains its word floor.\n        EXPECT_EQ(hash128_compare',1)
change('Laplace/app/Laplace.Core.Tests/Core/TextDecomposerTests.cs','Assert.Equal(1, word.GetNode','Assert.Equal(2, word.GetNode',1)
change('Laplace/app/Laplace.Substrate.Tests/Abstractions/TierFloorIdentityTests.cs','Assert.Equal(1, root.Tier); // Three scalar leaves, one composition above them.','Assert.Equal(2, root.Tier); // The Native word floor survives collapsed grapheme wrappers.',1)
for word,old,new in [('dog',1,2),('ab',1,2),('banana',1,2),('ab ab',2,3)]:
 change('Laplace/app/Laplace.Substrate.Tests/Abstractions/SharedContentStageParityTests.cs',f'[InlineData("{word}", {old})]',f'[InlineData("{word}", {new})]',1)
change('Laplace/app/Laplace.Substrate.Tests/Abstractions/TextEntityBuilderEmissionTests.cs','Assert.Equal((byte)1, rootTier); // A composition directly above scalars.','Assert.Equal((byte)2, rootTier); // Native retains the word floor.',1)
change('Laplace/app/Laplace.Substrate.Tests/Abstractions/TextEntityBuilderEmissionTests.cs','Assert.Equal((short)1, root.Tier);','Assert.Equal((short)2, root.Tier);',1)
change('Laplace/app/Laplace.Cli.Tests/IngestRosterParityTests.cs','Assert.Equal(sources, Laplace.Decomposers.Abstractions.EtlManifest.SourceOrder);\n        Assert.Equal(sources, IngestDispatchTable.CanonicalSourceKeys);','Assert.Equal(sources, Laplace.Decomposers.Abstractions.EtlManifest.ReadSourceOrder(\n            Laplace.Decomposers.Abstractions.EtlManifest.RecipesRoot));\n        Assert.Equal(Laplace.Decomposers.Abstractions.EtlManifest.SourceOrder, IngestDispatchTable.CanonicalSourceKeys);',1)
for old,new in [('"Pronunciation spelling of three\\t" + tag','"Pronunciation spelling of three\\tqualifier of this form or sense\\t" + tag'),('sense + "\\t" + tag','sense + "\\tqualifier of this form or sense\\t" + tag')]:
 change('Laplace/app/Laplace.Decomposers.Tests/Wiktionary/WiktionaryNativeRecipeTests.cs',old,new,1)
for value in ['Received-Pronunciation','British','Southern','Standard','General-American']:
 change('Laplace/app/Laplace.Decomposers.Tests/Wiktionary/WiktionaryNativeRecipeTests.cs','\\t'+value+'"','\\tqualifier of this form or sense\\t'+value+'"')
change('Laplace/app/Laplace.Endpoints.OpenAICompat.Tests/Goldens/explore-decompose-200.json','"tier": 1,','"tier": 2,',1)
# The account endpoint uses the existing statement catalog, with exactly the same
# parameters, joins and invitation authorization as its reviewed inline query.
p=mono/'app/Laplace.Endpoints.OpenAICompat/EndpointMappings.Account.cs'
data=p.read_bytes(); start=data.index(b'            await using var command = application.CreateCommand("""'); end=data.index(b'            await using var reader =',start)
query=data[start:end].decode().split('"""')[1]
lines=[line.strip() for line in query.strip().splitlines()]
catalog='SQL_QUERY("account.preview_invitation", "bytea,uuid",\n'+ '\n'.join('    "'+line.replace('"','\\"')+(' "' if i<len(lines)-1 else '")') for i,line in enumerate(lines))+'\n'
catalog_path=mono/'engine/core/src/sql_catalog.def'
catalog_path.write_bytes(catalog_path.read_bytes()+catalog.encode())
replacement=b'            await using var command = NpgsqlCatalog.Command(application, "account.preview_invitation",\r\n                SHA256.HashData(Encoding.UTF8.GetBytes(request.Token)), account.User);\r\n'
p.write_bytes(data[:start]+replacement+data[end:])
# Explicit codepoint products preserve generalized UTF-8 for surrogate values.
change('Laplace/app/Laplace.Substrate.Tests/Abstractions/NativeXmlRecipeTests.cs','InvalidScalarProductsFailBeforeTheyCanBecomeZeroChildEntities','SurrogateCodepointProductsRetainTheirNativeBytes',1)
change('Laplace/app/Laplace.Substrate.Tests/Abstractions/NativeXmlRecipeTests.cs','Assert.NotEqual(0, code);\n        Assert.Contains("invalid scalar content", Encoding.UTF8.GetString(error.ToArray()), StringComparison.Ordinal);\n        Assert.Contains(Path.GetFileName(path), Encoding.UTF8.GetString(error.ToArray()), StringComparison.Ordinal);','Assert.True(code == 0, Encoding.UTF8.GetString(error.ToArray()));\n        Assert.True(output.ToArray().AsSpan().IndexOf(new byte[] { 0xed, 0xa0, 0x80 }) >= 0,\n            "U+D800 must survive as its Native codepoint bytes.");',1)
# The Engine must use the same full Native floor for ranges and scalar lists.
p=root/'Laplace-Engine/src/record_values.c'; data=p.read_bytes(); start=data.index(b'/* A Unicode range can'); end=data.index(b'static int range_endpoint',start); data=data[:start]+data[end:]; data=data.replace(b'    if (non_scalar_address(p,n,out)) return 1;\n',b'').replace(b'        if (d->what==D_RANGE && non_scalar_address(p,n,out)) return 1;\n',b''); p.write_bytes(data)
p=root/'Laplace-Engine/tests/unicode-range-addresses.sh'; data=p.read_bytes(); data=data.replace(b'Unicode property ranges retain non-scalar addresses as content, not atoms.',b'Unicode property ranges retain every codepoint identity, including surrogates.'); data=data.replace(b"laplace_id('D800')",b'laplace_cp_id(55296)').replace(b"laplace_id('DFFF')",b'laplace_cp_id(57343)'); data=data.replace(b'       OR EXISTS (SELECT FROM public.entity WHERE id=laplace_cp_id(55296))\n',b''); start=data.index(b'# A sequence explicitly'); data=data[:start]+b'''# A declared codepoint sequence preserves a surrogate through publication.
mkdir -p "$scratch/surrogate"
printf 'SURROGATE CODEPOINT; D800\\n' > "$scratch/surrogate/NamedSequences.txt"
"$L" ingest --no-load -s unicode "$scratch/surrogate/NamedSequences.txt" > "$scratch/surrogate.log" 2>&1
python3 - "$scratch/surrogate.log" <<'PY'
from pathlib import Path
import sys
assert bytes.fromhex('eda080') in Path(sys.argv[1]).read_bytes(), 'surrogate codepoint bytes were lost'
PY
echo 'unicode-range-addresses: full codepoint floor, exact endpoints and published witness passed'
''';p.write_bytes(data)
change('Laplace-Engine/.github/workflows/laplace.yml','Unicode ranges retain non-scalar addresses without admitting atoms','Unicode ranges and sequences retain the complete codepoint floor',1)
print('Complete floor consumers and contract fixtures updated.')
