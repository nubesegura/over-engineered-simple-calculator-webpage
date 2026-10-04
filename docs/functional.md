# Functional documentation

The calculator page lets a logged-in user do arithmetic (add, subtract, multiply, divide) against a backend and see the history of calculations. The page is shared by every backend version; the user chooses the backend with the **Service URL** field.

## Who can use it

Only users created by the owner as administrator in Amazon Cognito. There is no sign-up, no "forgot password" and no second factor. Every user can use every backend.

## Login

1. When the page opens it briefly shows a loading indicator while it checks whether you are already logged in.
2. If you are not, you see the login screen with **Email** and **Password** fields and a **Log in** button. While the request runs the button shows progress.
3. On success the calculator appears without reloading the page.

### Wrong password or unknown user

The screen shows "The username or password is incorrect." (the same text for a wrong password and for an unknown user). Your typed email stays in the field and the password field is cleared.

Other messages you may see on the login screen:

| Situation | Message |
|---|---|
| The account needs an extra step (for example a temporary password that must be changed) | This account needs an extra step that this page does not support. Contact the administrator. |
| Too many attempts | Too many attempts. Wait a few minutes and try again. |
| The sign-in service is down | The sign-in service is temporarily unavailable. Try again shortly. |
| The server cannot be reached | Connection to the server failed. |

If the first check at page start fails for a reason other than "not logged in", the login screen shows the message and a **Try again** button.

## Coming back and the 24 hour session

- A session lasts **24 hours counted from the login**. If you log in in the morning and come back in the afternoon (same browser), the page recognizes you and shows the calculator without asking for the password.
- Using the page does **not** extend the session. Exactly 24 hours after the login you are asked to log in again, even if you were using it.
- Behind the scenes the page renews its short-lived token (1 hour) by itself; you do not notice it.

## Session expired while using the page

If the session cannot be renewed (it passed 24 hours, or it was revoked), the page returns to the login screen with the message "Your session has expired. Please log in again." Log in again to continue.

## Logout

The **Log out** button (top right of the calculator) ends the session: the page returns to the login screen. The session is also revoked on the server, so it cannot be reused. If the server cannot be reached, you are still logged out on this page and the session expires by itself within 24 hours of the login.

## Service URL

The **Service URL** field (below the title, after login) holds the backend address, including the version path. It is prefilled with the default backend. If it is empty or not an http(s) URL, the result area shows "Enter a valid Service URL (http:// or https://)." The page sends your login token to the backend automatically, but only to `https` addresses (or `http://localhost` and `http://127.0.0.1` for local runs). For any other `http` address it shows "The Service URL must use https." and sends nothing, so the token is never sent over an unencrypted connection.

## Calculations and history (unchanged)

- Type two numbers, choose an operation and press **Calculate**. The result is shown under the button.
- The **History** section is not loaded automatically: press the refresh button to load it. Once opened it refreshes 2 seconds after each successful calculation. **Load more** shows older entries.
- A backend without history shows "This service does not provide a history."
- If a backend rejects your token the page renews it once and retries; if it still fails you return to the login screen. If a backend answers "forbidden" the error is shown and you stay logged in.

## Windows desktop build

The Windows build has no login. It shows "Login is only available in the web version." instead of the login screen; use the web page.
