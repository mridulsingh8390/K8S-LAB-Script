# ---------------------------------------------------------------------------
# Dockerfile for mridulsingh8390/dotnet8 (HelloWorldApp.web)
#
# NOTE: I could browse the repo root (HelloWorldApp.sln + HelloWorldApp.web/
# folder, language mix HTML/C#/CSS/JS => ASP.NET Core Razor/MVC web app on
# .NET 8), but GitHub blocked deeper directory/raw access from this tool, so
# I could not read the exact .csproj filename or Program.cs. This Dockerfile
# uses the standard convention for a project named "HelloWorldApp.web"
# (i.e. HelloWorldApp.web.csproj -> HelloWorldApp.web.dll). If your actual
# .csproj has a different name, update the two lines marked CHANGE-ME below.
# ---------------------------------------------------------------------------

# ---- Build stage ----
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Copy solution and project file(s) first for better layer caching
COPY HelloWorldApp.sln ./
COPY HelloWorldApp.web/*.csproj HelloWorldApp.web/

RUN dotnet restore HelloWorldApp.sln

# Copy the rest of the source
COPY . .

WORKDIR /src/HelloWorldApp.web
RUN dotnet publish -c Release -o /app/publish --no-restore

# ---- Runtime stage ----
FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app

# Run as non-root (standard hardening for AKS)
RUN useradd -m appuser
USER appuser

COPY --from=build /app/publish .

ENV ASPNETCORE_HTTP_PORTS=8080
ENV ASPNETCORE_ENVIRONMENT=Production
EXPOSE 8080

# CHANGE-ME: confirm the DLL name matches your .csproj's AssemblyName
ENTRYPOINT ["dotnet", "HelloWorldApp.web.dll"]
