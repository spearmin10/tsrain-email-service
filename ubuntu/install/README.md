TSRAIN Email Service Installer
===========

Get Started
----------

### 1. Create a new instance
Minimum system requirements:
 - Architecture: x86 64-bits
 - CPU: 1 vCPU
 - RAM: 2 GB
 - Available Disk Space: 1 GB

### 2. Run install.sh on the instance

```
curl -s -L https://github.com/spearmin10/tsrain-email-service/blob/main/ubuntu/install/install.sh?raw=true | sudo bash
```

### 3. Open ports and access the services

Configure the inbound rules of the security group associated with your instance to allow access to the service ports. The ports used by the services are listed below, along with their access methods.

- TSRAIN Web Mail
  - https://&lt;your public ip&gt;/ or http://&lt;your public ip&gt;/
    - User ID: (any users)
    - Initial Password: TsrainDefault0!
  - https://&lt;your public ip&gt;/?admin or http://&lt;your public ip&gt;/?admin
    - User ID: admin
    - Password: (See RAINLOOP_DEFAULT_ADMIN_PASSWORD at /opt/tsrain/etc/.env)

- TSRAIN SMTP Service
  - Port: 25
  - STARTTLS is supported

- TSRAIN SMTP Service (SMTPS)
  - Port: 465
  - Port: 443

- TSRAIN IMAP4 Service
  - Port: 143
  - STARTTLS is supported

- TSRAIN IMAP4 Service (IMAPS)
  - Port: 993
  - Port: 443 (client auth)


Use your own server certificate
----------
### 1. Replace the certificate and private key
  - Server private key
    - /opt/tsrain/pki/server.key.pem
  - Server Certificate with intermediate and root CA certs
    - /opt/tsrain/pki/server.chain.pem
      - (This file should contain the server certificate, followed by any intermediate CA certificates, and then the root CA certificate, in that specific order.)

### 2. Restart the service.
  - sudo systemctl restart tsrain


Email Users and password
----------
All mailbox users in the TSRAIN instance share a single common password, and any password change made by one user is automatically applied to all users. When specifying a mailbox email address for login, you can use a wildcard address to access all mailboxes matching the pattern. The wildcard must include the `@` symbol to separate the user and domain parts; for example, `*@*` grants access to all mailboxes. Additionally, the special account `*` allows access to all mailboxes without specifying an email address.

All Services on Port 443
----------
To support environments where only port 443/TCP is accessible due to firewalls or other restrictions, TSRAIN serves WebMail (HTTPS), IMAPS, and SMTPS over a single port (443) by default.

#### Accessing from Clients
The port can identify the service based on a **client certificate** presented during the TLS handshake.
The installer automatically generates the following client certificates and private keys under `/opt/tsrain/pki/`:

* `tsrain-smtp-client.cer.pem` / `tsrain-smtp-client.key.pem`
* `tsrain-imap4-client.cer.pem` / `tsrain-imap4-client.key.pem`
* `tsrain-rainloop-client.cer.pem` / `tsrain-rainloop-client.key.pem`

Notes:
* For **IMAP4**, client certificate–based identification is **mandatory**.
* For **SMTP** and **WebMail (HTTPS)**, client certificates are **optional**. If not provided, the port identifies the target service based on the initial protocol behavior.

Managing TSRAIN Services
----------
TSRAIN services are managed using **systemd**.

#### Start the Services
```
sudo systemctl start tsrain
```

#### Stop the Services

```bash
sudo systemctl stop tsrain
```

#### Restart the Services
```
sudo systemctl restart tsrain
```

Licensing
----------
### Webmail Frontend
TSRAIN uses [RainLoop Webmail (Community Edition)](https://www.rainloop.net/) as its webmail frontend.  
RainLoop Webmail (Community Edition) is released under the [GNU Affero General Public License, Version 3 (AGPLv3)](http://www.gnu.org/licenses/agpl-3.0.html).  
For further details about licensing and disclaimers, please refer to the official RainLoop website.


