#Build
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS Build
WORKDIR /src
COPY . .
RUN dotnet publish -c Release -o /app

#Runtime
FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=Build /app .

ENV ASPNETCORE_URLS=http://+:8080
EXPOSE 8080
ENTRYPOINT [ "dotnet", "app.dll" ]
