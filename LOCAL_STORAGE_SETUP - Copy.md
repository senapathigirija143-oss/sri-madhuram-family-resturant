# Local restaurant portal

The application stores restaurant data in `.restaurant-data/store.json` and customer accounts in `.restaurant-data/customers.json`. It does not connect to Supabase or import records from a remote database.

## Run the application

```powershell
npm install
npm start
```

The server listens on port `3000` by default. Override it with `PORT` if needed.

## Store format and preservation

The JSON file must contain `menu`, `posters`, and `orders` arrays. Existing entries are read as-is and retained when a guest order is added. Writes are serialized and saved by atomic file replacement. If the file does not exist, the application starts with empty arrays; it does not create sample dishes, posters, or orders.

Keep regular backups of `.restaurant-data/store.json`. Run a single application process against this file; local JSON storage is not a multi-server database.

## Customer sign-in demo

1. Start the server with `npm start` and open `http://localhost:3000`.
2. Select **Sign In**, then **Register**.
3. Register with a name, 10-digit mobile number, email, and password (at least 8 characters).
4. Return to **Sign In**, choose **Customer**, and sign in with that mobile number and password.

No sample customer or default password is created. Passwords are stored as salted hashes. Email OTP is not used. Customer accounts and sessions are local to this server; signing in on another device or restarting the server does not restore an active session. Historical guest orders are preserved but are not exposed as customer account history.

The administrator email provided for this project is `senapathikumar3@gmail.com`. Admin and staff credentials are configured by the owner in the server's `.env` file:

```text
LOCAL_ADMIN_EMAIL=senapathikumar3@gmail.com
LOCAL_ADMIN_PASSWORD=choose-a-private-password
LOCAL_STAFF_EMAIL=staff@example.com
LOCAL_STAFF_PASSWORD=choose-a-private-password
```

Do not use these example values as real credentials. Do not share the `.env` file.

## Pricing

The default delivery fee is ₹30 per order and the default tax rate is 10%. They can be overridden with:

```text
RESTAURANT_DELIVERY_FEE=30
RESTAURANT_TAX_RATE=0.10
```

`RESTAURANT_TAX_RATE` is a fraction (`0.10` means 10%). The server calculates the order total from saved menu prices and these server-side values, not from prices or totals submitted by a browser.

## Payments and disabled features

Cash on delivery is available. Online UPI checkout is shown only when both `RAZORPAY_KEY_ID` and `RAZORPAY_KEY_SECRET` are configured. The secret must remain server-side.

Customer registration and login, plus protected staff/admin tools, use local accounts; account email/SMS OTP is not used. New orders receive an `ORD-######` number. While an order is out for delivery, that same six-digit number is shown as the delivery OTP and staff/admin must enter it before marking the order delivered. This code is not independent or secret because it is also the visible order number.

Customers can submit a cancellation request for an active order. An administrator can accept it, which cancels the order, or deny it, which leaves it active. A pending request must be reviewed before delivery can be completed. Accepting a cancellation does not initiate a refund or calculate a deduction; final cancellation/refund terms, including any deduction, require separate owner approval.
