using System.Text.Json;
using Npgsql;

try
{
    using var input = JsonDocument.Parse(Console.In.ReadToEnd());
    var connection = new NpgsqlConnectionStringBuilder(input.RootElement.GetProperty("connection").GetString());
    if (input.RootElement.TryGetProperty("password", out var password)) connection.Password = password.GetString();
    await using var source = NpgsqlDataSource.Create(connection.ConnectionString);
    await using var command = source.CreateCommand("SELECT current_user, ssl FROM pg_stat_ssl WHERE pid=pg_backend_pid()");
    await using var reader = await command.ExecuteReaderAsync();
    if (!await reader.ReadAsync() || !reader.GetBoolean(1)) throw new InvalidOperationException("TLS connection required");
    Console.WriteLine(JsonSerializer.Serialize(new { authenticated = true, role = reader.GetString(0), tls = true }));
    return 0;
}
catch (Exception error)
{
    var types = new List<string>();
    var mismatch = false;
    for (var inner = error; inner != null; inner = inner.InnerException)
    {
        types.Add(inner.GetType().Name);
        mismatch |= inner.Message.Contains("MapOpenSsl30Code") && inner.Message.Contains("'30'");
    }
    Console.WriteLine(JsonSerializer.Serialize(new { authenticated = false, errors = types, openssl_identifier_mismatch = mismatch }));
    return 1;
}
