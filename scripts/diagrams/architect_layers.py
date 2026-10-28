"""Layers diagram of the web page (docs/architect_layers.drawio): horizontal tier swimlanes.

Run from anywhere:
    python scripts/diagrams/architect_layers.py [html-dir]
Writes docs/architect_layers.drawio and architect_layers.html (viewer page used to export
docs/architect_layers.png with headless Chrome) into html-dir (default: the system temp folder).
"""

import sys
import tempfile
from html import escape
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from drawio_lib import Diagram, viewer_html  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "architect_layers.drawio"
HTML_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(tempfile.gettempdir())

# ---- grid -------------------------------------------------------------------------------------
LANE_X, STRIP = 20, 60
COL0, COLW, BOXW = 110, 250, 210
LANE_H = 230
TOP = 110
BOX_DY, BOX_H = 60, 90
NCOL = 8
LANE_W = COL0 + COLW * NCOL - LANE_X


def col_x(i: int) -> int:
    return COL0 + COLW * i


def col_cx(i: int) -> int:
    return col_x(i) + BOXW // 2


def lane_top(k: int) -> int:
    return TOP + LANE_H * k


W, H = LANE_X + LANE_W + 40, 1790
d = Diagram("Web page layers", W, H)

TIERS = [
    ("Client tier", "#f5f5f5"),
    ("Edge and identity tier", "#e8f4f8"),
    ("API tier", "#f3e9f7"),
    ("Compute tier", "#e8f5e9"),
    ("Data and messaging tier", "#fff0e6"),
    ("Platform tier", "#fce4ec"),
]
for k, (name, fill) in enumerate(TIERS):
    d.cells.append(
        f'<mxCell id="lane{k}" value="{escape(name, quote=True)}" '
        f'style="swimlane;horizontal=0;startSize={STRIP};fillColor={fill};html=1;fontStyle=1;fontSize=15;'
        f'strokeColor=#232F3E;" vertex="1" parent="1">'
        f'<mxGeometry x="{LANE_X}" y="{lane_top(k)}" width="{LANE_W}" height="{LANE_H}" as="geometry"/></mxCell>'
    )

d.text(
    "title",
    20,
    18,
    LANE_W,
    70,
    "<b>Over-engineered calculator web page - layers (dev and prod, us-east-2 with a global edge)</b><br>"
    "Solid arrow: request, data or deploy path. Dashed arrow: DNS, certificate, alert or call to another repository.",
    fs=16,
)

STYLES = {
    "plain": ("#ffffff", "#666666", False),
    "edge": ("#b1ddf0", "#10739e", False),
    "api": ("#e1d5e7", "#9673a6", False),
    "compute": ("#d5e8d4", "#82b366", False),
    "data": ("#ffe6cc", "#d79b00", False),
    "platform": ("#f8cecc", "#b85450", False),
    "external": ("#fff7e0", "#b7791f", True),
}


def box(cid: str, col: int, lane: int, kind: str, title: str, sub: str = "") -> None:
    fill, stroke, dashed = STYLES[kind]
    label = f"<b>{title}</b>" + (f"<br>{sub}" if sub else "")
    d.box(
        cid,
        col_x(col),
        lane_top(lane) + BOX_DY,
        BOXW,
        BOX_H,
        label,
        fill=fill,
        stroke=stroke,
        dashed=dashed,
        sw=1,
        valign="middle",
        align="center",
        fs=12,
        bold=False,
        arc=12,
    )


# client
box("users", 2, 0, "plain", "Users", "Flutter Web page in the browser")
box("cli", 5, 0, "plain", "Websocket CLI and e2e", "other repository, public client ID")
box("owner", 6, 0, "plain", "Owner", "email alerts, creates users")
# edge and identity
box("waf", 0, 1, "external", "Shared WAF web ACL", "prod only, by ARN, not in this repo")
box("r53", 1, 1, "edge", "Route 53", "A and AAAA alias records")
box("cf", 2, 1, "edge", "CloudFront", "OAC, TLS 1.2+, HSTS and CSP")
box("acm", 3, 1, "edge", "ACM certificate", "us-east-1, DNS validated")
box("cog", 5, 1, "edge", "Cognito user pool", "confidential client (BFF), public client (CLI)")
# api
box("url", 4, 2, "api", "BFF function URL", "/auth/* only, AWS_IAM, signed by CloudFront")
box("backends", 7, 2, "external", "Backends sls and ecs", "other repositories, /api/v1")
# compute
box("bff", 4, 3, "compute", "BFF Lambda", "login, refresh, logout; Python 3.14 arm64")
# data
box("s3", 2, 4, "data", "S3 web bucket", "private, versioned, compiled page")
box("sm", 4, 4, "data", "Secrets Manager secret", "app client secret, AWS managed key")
box("alarms", 6, 4, "data", "Alarms and alert topics", "BFF errors, throttles; cert 30 and 7 d")
# platform
box("gh", 0, 5, "platform", "GitHub Actions", "OIDC role, owner guard, IAC_TOOL")
box("cfn", 1, 5, "platform", "CloudFormation / SAM", "4 stacks, guarded change sets (dev)")
box("tf", 2, 5, "platform", "Terraform (Terragrunt)", "prod owner until backlog B003")
box("art", 3, 5, "external", "Shared artifacts bucket", "add-ons repo, BFF package")
box("cw", 4, 5, "platform", "CloudWatch Logs", "BFF log group, 30 d dev, 365 d prod")
box("iam", 5, 5, "platform", "IAM", "BFF role: logs, one GetSecretValue")

# ---- flows ----------------------------------------------------------------------------------------
V, N = (0.5, 1), (0.5, 0)
c0 = lane_top(0) + 30  # corridor above the client boxes
c2 = lane_top(2) + 30  # corridor above the API boxes
y_bff_hi = lane_top(3) + BOX_DY + 0.25 * BOX_H
y_bff_lo = lane_top(3) + BOX_DY + 0.75 * BOX_H
p1 = lane_top(5) + BOX_DY + BOX_H + 25  # corridors below the platform boxes
p2 = lane_top(5) + BOX_DY + BOX_H + 55

d.edge("users", "cf", V, N, num=1)
d.edge("r53", "cf", (1, 0.5), (0, 0.5), num=2, dashed=True)
d.edge("acm", "cf", (0, 0.5), (1, 0.5), num=3, dashed=True)
d.edge("cf", "s3", V, N, num=4, lp=0.6)
d.edge("cf", "url", (0.9, 1), N, [(col_x(2) + 189, c2), (col_cx(4), c2)], num=5)
d.edge("url", "bff", V, N, num=6)
d.edge("bff", "sm", V, N, num=7)
d.edge("bff", "cog", (1, 0.25), V, [(col_cx(5), y_bff_hi)], num=8, lp=0.3)
d.edge("users", "backends", (0.8, 0), N, [(col_x(2) + 168, c0), (col_cx(7), c0)], num=9, dashed=True)
d.edge("bff", "alarms", (1, 0.75), (0.3, 0), [(col_x(6) + 63, y_bff_lo)], num=10, dashed=True, lp=-0.3)
d.edge("alarms", "owner", (0.7, 0), (0.7, 1), num=11, dashed=True, lp=0.6)
d.edge("gh", "cfn", (1, 0.5), (0, 0.5), num=12)
d.edge("gh", "tf", (0.4, 1), V, [(col_x(0) + 84, p1), (col_cx(2), p1)], num=13, lp=0.3)
d.edge("cli", "cog", V, N, num=15)
d.edge("gh", "art", (0.7, 1), V, [(col_x(0) + 147, p2), (col_cx(3), p2)], num=14, lp=0.5)

# ---- legend and notes --------------------------------------------------------------------------------
LEG_Y = lane_top(6) + 40
d.box("legend", 20, LEG_Y, LANE_W, 230, "", fill="#ffffff", stroke="#232F3E", sw=1, arc=0)
half = (LANE_W - 60) // 2
d.text(
    "legL",
    40,
    LEG_Y + 12,
    half,
    210,
    "<b>Flow legend</b><br>"
    "[1] Users open the page over HTTPS through CloudFront. [2] Route 53 points the domain at CloudFront (DNS). "
    "[3] The us-east-1 certificate serves TLS on the custom domain.<br>"
    "[4] CloudFront reads the private web bucket with origin access control. [5] CloudFront sends /auth/* to the "
    "BFF function URL, signed. [6] The URL invokes the BFF.<br>"
    "[7] The BFF reads the app client secret once per execution environment. [8] The BFF calls Cognito with "
    "the secret hash or the secret (login, refresh, revoke).<br>"
    "[9] The page calls the backends of other repositories with the ID token. [10] BFF metrics feed the alarms; "
    "[11] both alert topics email the owner.<br>"
    "[12] GitHub Actions deploys with CloudFormation/SAM (default) after the owner guard; [13] with "
    "IAC_TOOL=terraform it runs Terragrunt; [14] it uploads the BFF package to the shared artifacts bucket.<br>"
    "[15] The websocket CLI and e2e tests sign in directly at Cognito with the public client (no secret, "
    "USER_PASSWORD_AUTH and refresh; no CloudFront, BFF or WAF) and call the websocket backend with the ID token.",
    fs=13,
)
d.text(
    "legR",
    40 + half + 20,
    LEG_Y + 12,
    half,
    210,
    "<b>Notes</b><br>"
    "One tool owns an environment at a time: dev is CloudFormation-owned (stacks auth, cert, auth-bff, frontend); "
    "prod stays Terraform-owned until backlog B003, and the owner guard stops a CloudFormation deploy there.<br>"
    "The auth stack fills the secret from the app client attribute at deploy time; the secret has no rotation, "
    "a TLS-only resource policy and one reader role.<br>"
    "No VPC: the BFF reaches Cognito and Secrets Manager over their public endpoints with TLS.<br>"
    "The refresh token lives only in an HttpOnly cookie; ID and access tokens only in page memory.<br>"
    "Refresh tokens are bound to their client: a public-client refresh token sent to the BFF is refused by Cognito.<br>"
    "The components view (architect_components.drawio) shows the same system as AWS resources per Region and stack.",
    fs=13,
)

xml = d.xml()
OUT.write_bytes(xml.encode("utf-8"))
(HTML_DIR / "architect_layers.html").write_bytes(viewer_html(xml, W, H).encode("utf-8"))
print("written", OUT, W, H)
