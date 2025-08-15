var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/", () => new {
    message = "Hello from AKS via ACR image!",
    time = DateTime.UtcNow
});

app.Run();
