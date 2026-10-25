"""AWS components diagram of the web page (docs/architect_components.drawio).

Run from anywhere:
    python scripts/diagrams/architect_components.py [html-dir]
Writes docs/architect_components.drawio and architect_components.html (viewer page used to export
docs/architect_components.png with headless Chrome) into html-dir (default: the system temp folder).
Source of the content: templates/*.yaml, templates/stacks.json and modules/ (same resources, same names).
"""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from drawio_lib import NAVY, Diagram, viewer_html  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "architect_components.drawio"
HTML_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(tempfile.gettempdir())

W, H = 2900, 2530
d = Diagram("Web page AWS components", W, H)

# ---- title -------------------------------------------------------------------------------------
d.box(
    "title",
    40,
    20,
    2820,
    60,
    "Over-engineered calculator web page - AWS components (one AWS account per environment: dev, prod)",
    fill=NAVY,
    stroke=NAVY,
    fcolor="#ffffff",
    fs=22,
    valign="middle",
)

# ---- containers (first, so icons and arrows sit on top) -------------------------------------------
d.box(
    "acct",
    340,
    130,
    2100,
    1910,
    "AWS account of the environment - no VPC. dev: owned by CloudFormation (4 stacks). "
    "prod: same resources, owned by Terraform until backlog B003",
    stroke=NAVY,
    sw=3,
    fs=15,
)
d.box(
    "edge",
    380,
    190,
    680,
    810,
    "Global edge - stack stk-useast2-oecalc-frontend-&lt;env&gt;",
    fill="#faf5ff",
    stroke="#8C4FFF",
)
d.box(
    "use1",
    380,
    1060,
    680,
    560,
    "Region us-east-1 - stack stk-useast1-oecalc-cert-&lt;env&gt;",
    fill="#f4f9ff",
    stroke="#147EBA",
    valign="bottom",
)
d.box("use2", 1100, 190, 1320, 1430, "Region us-east-2", fill="#f4f9ff", stroke="#147EBA", fs=16)
d.box("gFront", 1140, 360, 560, 280, "Stack stk-useast2-oecalc-frontend-&lt;env&gt;", fill="#ffffff", stroke="#7AA116")
d.box(
    "gBff", 1140, 740, 860, 440, "Stack stk-useast2-oecalc-auth-bff-&lt;env&gt; (SAM)", fill="#ffffff", stroke="#ED7100"
)
d.box(
    "gAuth",
    1140,
    1240,
    860,
    360,
    "Stack stk-useast2-oecalc-auth-&lt;env&gt;",
    fill="#ffffff",
    stroke="#DD344C",
    valign="bottom",
)
d.box("gArt", 2060, 1240, 330, 360, "Add-ons repository (shared)", fill="#fafafa", stroke="#7f7f7f", dashed=True)
d.box(
    "cross",
    380,
    1720,
    2040,
    270,
    "Cross-cutting: delivery, identity of the function and logs",
    fill="#ffffff",
    stroke="#E7157B",
)

# ---- external actors -------------------------------------------------------------------------------
UX, UY = 170, 500
d.icon("users", UX, UY, "users", "user", "Users<br>browser, Flutter Web")
d.box(
    "gh",
    40,
    1780,
    260,
    100,
    "GitHub Actions<br>OIDC deploy role<br>owner guard, change-set guard",
    fill="#f1f5f9",
    stroke="#334155",
    valign="middle",
    align="center",
    bold=False,
    fs=13,
)
d.box(
    "backends",
    2480,
    400,
    380,
    160,
    "Backends sls and ecs (other repositories)<br>https://api.&lt;host&gt;/api/v1<br>"
    "hostname and records owned by<br>the shared-resources repository",
    fill="#fafafa",
    stroke="#7f7f7f",
    dashed=True,
    valign="middle",
    align="center",
    bold=False,
    fs=13,
)
d.box(
    "email",
    2480,
    850,
    380,
    100,
    "Owner email<br>(subscription of the BFF alert topic)",
    fill="#f1f5f9",
    stroke="#334155",
    valign="middle",
    align="center",
    bold=False,
    fs=13,
)

d.box(
    "cli",
    40,
    1180,
    260,
    120,
    "Websocket CLI and e2e tests<br>developer machine or CI runner<br>(other repository)",
    fill="#f1f5f9",
    stroke="#334155",
    valign="middle",
    align="center",
    bold=False,
    fs=13,
)

d.box(
    "email1",
    40,
    1410,
    260,
    100,
    "Owner email<br>(subscription of the<br>web alert topic)",
    fill="#f1f5f9",
    stroke="#334155",
    valign="middle",
    align="center",
    bold=False,
    fs=13,
)

# ---- global edge -----------------------------------------------------------------------------------
d.icon("r53", 520, 300, "route_53", "net", "Route 53<br>A and AAAA alias", lab="right")
d.box(
    "waf",
    820,
    240,
    210,
    120,
    "Shared WAF web ACL<br>prod only, by ARN<br>(not in this repo)",
    fill="#ffffff",
    stroke="#8C4FFF",
    dashed=True,
    valign="middle",
    align="center",
    bold=False,
    fs=12,
)
d.icon("cf", 760, 500, "cloudfront", "net", "CloudFront distribution<br>cfd-useast2-oecalc-web-&lt;env&gt;")
d.text(
    "cfnote",
    640,
    640,
    390,
    120,
    "Same stack: web and BFF origin access controls, response headers policy (HSTS, CSP), "
    "two Lambda permissions, behavior /auth/* to the BFF.",
    fs=12,
)

# ---- us-east-1 ----------------------------------------------------------------------------------------
d.icon("acm", 600, 1200, "certificate_manager_3", "sec", "ACM certificate<br>DNS validated")
d.icon("alm1", 600, 1460, "cloudwatch_2", "mgmt", "2 expiry alarms<br>30 and 7 days")
d.icon("sns1", 800, 1460, "sns", "integ", "sns-useast1-oecalc-<br>web-alerts-&lt;env&gt;", lab="right")

# ---- us-east-2 ------------------------------------------------------------------------------------------
d.icon("s3web", 1300, 500, "s3", "storage", "Web bucket bckt-useast2-<br>oecalc-web-&lt;env&gt;-&lt;acct&gt;")
d.text(
    "frnote", 1420, 440, 260, 120, "Private, versioned, SSE-S3, TLS-only policy, read only by this distribution.", fs=12
)
d.icon("bff", 1300, 900, "lambda", "compute", "BFF fnc-useast2-oecalc-<br>auth-bff-&lt;env&gt; + URL", lab="above")
d.icon("alm2", 1560, 900, "cloudwatch_2", "mgmt", "2 alarms<br>Errors, Throttles")
d.icon("sns2", 1820, 900, "sns", "integ", "sns-useast2-oecalc-<br>auth-bff-alerts-&lt;env&gt;")
d.icon(
    "cog",
    1300,
    1380,
    "cognito",
    "sec",
    "User pool cgnp-<br>confidential client cgnc- (BFF)<br>public client cgnc-...-wscli-",
)
d.text(
    "cognote",
    1360,
    1262,
    290,
    76,
    "Public client: no secret, USER_PASSWORD_AUTH and refresh only. "
    "Its refresh tokens are refused at the BFF (different client).",
    fs=12,
)
d.icon("sm", 1700, 1380, "secrets_manager", "sec", "Secret sm-useast2-oecalc-<br>auth-app-client-&lt;env&gt;")
d.icon("art", 2300, 1400, "s3", "storage", "Artifacts bucket<br>prefix of this repo", lab="left")

# ---- cross-cutting band ---------------------------------------------------------------------------------
BY = 1830
d.icon("cfn", 600, BY, "cloudformation", "mgmt", "CloudFormation<br>4 stacks, change sets")
d.icon("iam", 1000, BY, "identity_and_access_management", "sec", "BFF execution role<br>iamr-...-auth-bff-&lt;env&gt;")
d.icon("cwl", 1400, BY, "cloudwatch_2", "mgmt", "BFF log group<br>30 d dev, 365 d prod")
d.box(
    "tfstate",
    1640,
    1775,
    340,
    110,
    "Terraform state (prod)<br>bucket outside this repository<br>until backlog B003",
    fill="#ffffff",
    stroke="#7f7f7f",
    dashed=True,
    valign="middle",
    align="center",
    bold=False,
    fs=13,
)

# ============================ arrows (numbers explained in the legend) ==================================
d.edge("users", "cf", (1, 0.5), (0, 0.5), num=1, lp=-0.4)
d.edge("r53", "cf", (0.5, 1), (0, 0.2), [(520, 476.6)], num=2, dashed=True, lp=-0.3)
d.edge("cf", "s3web", (1, 0.5), (0, 0.5), num=3, lp=-0.55)
d.edge("cf", "bff", (1, 0.8), (0, 0.5), [(1080, 523.4), (1080, 900)], num=4, lp=0.9)
d.edge("bff", "sm", (0.8, 1), (0.5, 0), [(1323.4, 1100), (1700, 1100)], num=5, lp=0.1)
d.edge("bff", "cog", (0.5, 1), (0.5, 0), num=6, lp=-0.45)
d.edge("users", "backends", (0.5, 0), (0.5, 0), [(UX, 105), (2670, 105)], num=7, dashed=True, lp=0.0)
d.edge("acm", "cf", (0.5, 0), (0, 0.8), [(600, 523.4)], num=8, dashed=True, lp=-0.1)
d.edge("cog", "sm", (1, 0.5), (0, 0.5), num=9, dashed=True)
d.edge("alm2", "sns2", (1, 0.5), (0, 0.5), num=10, dashed=True)
d.edge("sns2", "email", (1, 0.5), (0, 0.5), num=11, dashed=True, lp=0.3)
d.edge("alm1", "sns1", (1, 0.5), (0, 0.5), num=12, dashed=True)
d.edge("sns1", "email1", (0.5, 1), (0.5, 1), [(800, 1670), (170, 1670)], num=13, dashed=True, lp=0.0)
d.edge("gh", "cfn", (1, 0.5), (0, 0.5), num=14, lp=-0.3)
d.edge("gh", "art", (0.5, 1), (0.5, 1), [(170, 2090), (2300, 2090)], num=15, lp=0.0)
d.edge("cli", "cog", (1, 0.5), (0, 0.5), [(320, 1240), (320, 1380)], num=16, lp=0.2)

# ---- legend and notes ------------------------------------------------------------------------------------
LY = 2150
d.box("legend", 40, LY, 2820, 350, "Legend and notes", fill="#f8fafc", stroke=NAVY, fs=16)
left = (
    "<b>Requests</b><br>"
    "[1] Users open the page over HTTPS on the custom domain (TLS 1.2 or later; prod adds the shared WAF).<br>"
    "[2] Route 53 A and AAAA alias records point the domain at the distribution (dotted: DNS).<br>"
    "[3] CloudFront reads the private web bucket with origin access control (SigV4).<br>"
    "[4] CloudFront sends /auth/* (login, refresh, logout) to the BFF function URL, signed (OAC, AWS_IAM).<br>"
    "[5] The BFF reads the app client secret once per execution environment (secretsmanager:GetSecretValue).<br>"
    "[6] The BFF calls Cognito InitiateAuth, GetTokensFromRefreshToken and RevokeToken "
    "with the secret hash or secret (confidential client only).<br>"
    "[7] The page calls the backends directly with the ID token as bearer (dotted: other repositories).<br>"
    "[8] The us-east-1 certificate is attached to the distribution (passed to stack frontend by the deploy script).<br>"
    "[9] At deploy time the auth stack fills the secret from the app client attribute ClientSecret (dotted).<br>"
    "[16] The websocket CLI and e2e tests sign in directly at Cognito with the public client ID "
    "(USER_PASSWORD_AUTH, refresh, revoke; TLS, no BFF, no WAF, no secret), then call the websocket "
    "backend with the ID token. A public-client refresh token sent to the BFF /auth/refresh is refused "
    "by Cognito (different client)."
)
right = (
    "<b>Alerts and delivery</b><br>"
    "[10] [11] BFF Errors and Throttles alarms notify the us-east-2 topic, which emails the owner.<br>"
    "[12] [13] Certificate expiry alarms (30 and 7 days) notify the us-east-1 topic, which emails the owner.<br>"
    "[14] GitHub Actions deploys the stacks in order auth, cert, auth-bff, frontend through guarded change sets, "
    "after the owner guard; IAC_TOOL=terraform runs Terragrunt instead.<br>"
    "[15] The BFF package and the templates are uploaded to the shared artifacts bucket (name read from SSM).<br><br>"
    "<b>Notes</b><br>"
    "Secret: AWS managed key, no rotation, TLS-only resource policy, public policies blocked, one reader role. "
    "The public client has no secret.<br>"
    "prod stacks (after B003): termination protection and a stack policy against replacing or deleting the pool, "
    "clients, secret, distribution and bucket. Until then prod is Terraform-owned and the owner guard stops a "
    "CloudFormation deploy there.<br>"
    "Solid arrow: request or deploy path. Dotted arrow: DNS, deploy-time value, alert or external call. "
    "Dashed box: owned outside this repository or prod only."
)
d.text("legL", 70, LY + 50, 1360, 290, left, fs=15)
d.text("legR", 1470, LY + 50, 1360, 290, right, fs=15)

xml = d.xml()
OUT.write_bytes(xml.encode("utf-8"))
(HTML_DIR / "architect_components.html").write_bytes(viewer_html(xml, W, H).encode("utf-8"))
print("written", OUT, W, H)
