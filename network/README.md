# Environment routes

`environments.json` declares the browser origin independently of the service's loopback listener. It also declares
the existing OAuth clients and their callback paths. Client IDs are public; credentials do not belong in this file.

`configure-dns.ps1 -Apply` creates the declared private CNAMEs using the existing Cloudflare login and reads them back.
It refuses conflicting records. `configure-redirects.py --azure-config <provider-management login> --apply` unions the
Microsoft callback URLs with the existing registration and reads back the result. It does not grant permissions to
the runtime identity. Google web-client registration is managed in Google Auth Platform, project
`gen-lang-client-0624169393`; the gcloud IAM OAuth-client commands manage Workforce Identity Federation clients.

`setup.sh site` installs the private nginx HTTPS route for a matching host from this declaration. The existing
hart-server wildcard certificate is used in place. It validates certificate coverage, nginx configuration and an
actual HTTPS health request, restoring the prior nginx configuration on failure. It does not issue a certificate or
claim renewal is configured. It leaves the internal service listener and other nginx sites in place.

IIS installation, publication and verification must consume the same machine declaration: `LAPLACE_IIS_API`,
`LAPLACE_IIS_SITE`, `LAPLACE_IIS_POOL`, `LAPLACE_PUBLIC_BASE_URL` and `LAPLACE_IIS_CERTIFICATE_THUMBPRINT`.
The certificate must be installed in LocalMachine/My. IIS bindings and certificate installation are elevated setup
operations; an answering Kestrel process does not prove the IIS application is installed.

Run `acceptance/verify.ps1 -Check browser-routes -Output <new receipt>` on hart-desktop to check the declared browser
origins. It checks DNS/TLS, the SPA, application health and exact Google/Microsoft redirect origins. It stores no
OAuth state or credentials and does not claim a generated redirect proves provider registration or completed login.

References: [ASP.NET Core proxy configuration](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/proxy-load-balancer?view=aspnetcore-10.0),
[IIS hosting](https://learn.microsoft.com/en-us/aspnet/core/host-and-deploy/iis/?view=aspnetcore-10.0),
[nginx proxy headers](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_set_header),
[Google web-client registration](https://support.google.com/cloud/answer/15549257?hl=en),
[Microsoft callback registration](https://learn.microsoft.com/en-us/entra/identity-platform/reply-url).
