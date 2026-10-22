using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
// Actual pinned source declarations only. Never load/build the upstream SDK project.
try
{
    if (args.Length != 4) throw new InvalidDataException();
    var source = File.ReadAllBytes(args[0]);
    if (Convert.ToHexStringLower(SHA256.HashData(source)) != "2b85b8f2ca07ec8cc7ef3b65890ffb7c36ec1371df637802689c6b92a4c38b19") throw new InvalidDataException();
    var tree = CSharpSyntaxTree.ParseText(Encoding.UTF8.GetString(source).TrimStart('\uFEFF'));
    if (tree.GetDiagnostics().Any(d => d.Severity == DiagnosticSeverity.Error)) throw new InvalidDataException();
    var root = tree.GetCompilationUnitRoot();
    if (root.Members.Count != 1 || root.Members[0] is not FileScopedNamespaceDeclarationSyntax space || space.Name.ToString() != "HIDMaestro") throw new InvalidDataException();
    string[] names = ["HMGamepadState", "HMAxis", "HMButton", "HMHat"];
    HashSet<string> fieldTypes = ["Dictionary<HMAxis,float>?", "HMButton", "HMHat", "bool", "byte", "float", "float?", "int?", "short", "uint", "ushort", "ushort?"];
    var output = new StringBuilder("// Exact pinned data declarations; NOT the official SDK assembly.\nusing System;\nusing System.Collections.Generic;\nnamespace HIDMaestro;\n");
    var hashes = new Dictionary<string,string>();
    foreach (var name in names)
    {
        var nodes = space.Members.OfType<BaseTypeDeclarationSyntax>().Where(n => n.Identifier.ValueText == name).ToArray();
        if (nodes.Length != 1) throw new InvalidDataException();
        var node = nodes[0];
        if (node.DescendantTrivia().Any(t => t.IsDirective) || node.Modifiers.Count != 1 || !node.Modifiers[0].IsKind(SyntaxKind.PublicKeyword)) throw new InvalidDataException();
        if (name == "HMGamepadState")
        {
            if (node is not StructDeclarationSyntax state || state.AttributeLists.Count != 0 || state.BaseList != null || state.TypeParameterList != null) throw new InvalidDataException();
            foreach (var member in state.Members)
                if (member is not FieldDeclarationSyntax field || field.AttributeLists.Count != 0 || field.Modifiers.Count != 1 || !field.Modifiers[0].IsKind(SyntaxKind.PublicKeyword) || !fieldTypes.Contains(field.Declaration.Type.ToString().Replace(" ", "")) || field.Declaration.Variables.Any(v => v.Initializer != null)) throw new InvalidDataException();
        }
        else
        {
            if (node is not EnumDeclarationSyntax enumeration || enumeration.AttributeLists.SelectMany(a => a.Attributes).Any(a => a.Name.ToString() != "Flags" || a.ArgumentList != null)) throw new InvalidDataException();
            var expectedBase = name switch { "HMAxis" => "ushort", "HMButton" => "uint", "HMHat" => "byte", _ => throw new InvalidDataException() };
            if (enumeration.BaseList?.Types.Count != 1 || enumeration.BaseList.Types[0].Type.ToString() != expectedBase) throw new InvalidDataException();
            foreach (var member in enumeration.Members)
                if (member.AttributeLists.Count != 0 || member.EqualsValue == null || member.EqualsValue.Value.DescendantNodesAndSelf().Any(n => n is not (LiteralExpressionSyntax or BinaryExpressionSyntax or IdentifierNameSyntax))) throw new InvalidDataException();
        }
        var exact = node.ToFullString(); output.Append(exact).AppendLine(); hashes[name] = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(exact)));
    }
    if (File.Exists(args[1]) || File.Exists(args[2])) throw new InvalidDataException();
    File.WriteAllText(args[1], output.ToString(), new UTF8Encoding(false));
    File.WriteAllText(args[2], JsonSerializer.Serialize(new { version = 1, scope = "data-type-api-subset-not-official-sdk", sourceSha256 = Convert.ToHexStringLower(SHA256.HashData(source)), declarations = hashes }));
    var license = File.ReadAllBytes(args[3]);
    if (Convert.ToHexStringLower(SHA256.HashData(license)) != "1b637c35922ac7a519d208afb8b45e278597d896f7ff799eff375f0753470790") throw new InvalidDataException();
    Console.WriteLine("candidate_data_declarations_verified");
    return 0;
}
catch { Console.Error.WriteLine("candidate_data_declarations_rejected"); return 1; }
