# Parallel Localization Task — imghost

## Your Assignment

You are implementing **one language** from this list. Each subagent gets exactly one:

| Subagent | Language | Code | lproj folder |
|---|---|---|---|
| Agent 1 | Mandarin (Simplified) | zh-Hans | `zh-Hans.lproj` |
| Agent 2 | German | de | `de.lproj` |
| Agent 3 | Dutch | nl | `nl.lproj` |
| Agent 4 | French | fr | `fr.lproj` |
| Agent 5 | Italian | it | `it.lproj` |
| Agent 6 | Portuguese (Brazil) | pt-BR | `pt-BR.lproj` |
| Agent 7 | Korean | ko | `ko.lproj` |

> Spanish (`es`) and Japanese (`ja`) are already done — do NOT redo them.

---

## What You Must Do

### 1. Create 4 translation files

Create `Localizable.strings` in your language's `.lproj` folder inside each of these 4 target directories:

```
/Users/codybontecou/dev/imghost/frontend/imghost/imghost/{LANG}.lproj/Localizable.strings
/Users/codybontecou/dev/imghost/frontend/imghost/imghostMac/{LANG}.lproj/Localizable.strings
/Users/codybontecou/dev/imghost/frontend/imghost/ShareExtension/{LANG}.lproj/Localizable.strings
/Users/codybontecou/dev/imghost/frontend/imghost/MacShareExtension/{LANG}.lproj/Localizable.strings
```

Replace `{LANG}` with your language code (e.g. `de`, `fr`, `zh-Hans`).

The `imghost` (iOS) and `imghostMac` (macOS) files share the **same keys** but the macOS file has **additional keys** (see Mac-specific section below). Create both files with full content.

### 2. Register in Xcode project

Run this Ruby script to add your language to the project:

```ruby
#!/usr/bin/env ruby
# Save as /tmp/add_lang.rb, set LANG_CODE, then: ruby /tmp/add_lang.rb

require 'xcodeproj'

LANG_CODE = 'de'  # <-- CHANGE THIS to your language code
PROJECT_PATH = '/Users/codybontecou/dev/imghost/frontend/imghost/imghost.xcodeproj'

project = Xcodeproj::Project.open(PROJECT_PATH)

TARGETS = {
  'imghost'           => 'imghost',
  'ShareExtension'    => 'ShareExtension',
  'imghostMac'        => 'imghostMac',
  'MacShareExtension' => 'MacShareExtension',
}

TARGETS.each do |target_name, group_path|
  target = project.targets.find { |t| t.name == target_name }
  next unless target

  main_group = project.main_group.find_subpath(group_path)
  next unless main_group

  variant_group = main_group.children.find { |c|
    c.is_a?(Xcodeproj::Project::Object::PBXVariantGroup) && c.name == 'Localizable.strings'
  }
  next unless variant_group

  existing = variant_group.children.find { |c| c.name == LANG_CODE }
  if existing
    puts "Already present: #{target_name}/#{LANG_CODE}"
    next
  end

  ref = variant_group.new_file("#{LANG_CODE}.lproj/Localizable.strings")
  ref.name = LANG_CODE
  ref.last_known_file_type = 'text.plist.strings'
  puts "Added #{LANG_CODE} to #{target_name}"
end

unless project.root_object.known_regions.include?(LANG_CODE)
  project.root_object.known_regions << LANG_CODE
  puts "Added #{LANG_CODE} to knownRegions"
end

project.save
puts "Saved."
```

Run it with: `ruby /tmp/add_lang.rb`

### 3. Commit

```bash
cd /Users/codybontecou/dev/imghost
git add frontend/imghost/
git commit -m "i18n: add {LANGUAGE} ({LANG_CODE}) translations"
git pull --rebase && git push
```

---

## Critical Rules

1. **Keep ALL format specifiers exactly as-is**: `%@`, `%d`, `%.1f`, `%#@`, `%d%%`, `"\n"` in the original must appear unchanged in your translation. The argument order must be preserved.
2. **Key strings stay unchanged** — only translate the right-hand side value.
3. **ALL CAPS style**: Many English values are uppercase (`"CANCEL"`, `"UPLOADING"`, etc.). Match the **natural convention for your language**. German, Dutch, French, Italian, Portuguese naturally use title case or sentence case — don't force all-caps for regular words. Short action labels (buttons) can be uppercase. Korean, Chinese, and Japanese never use letter-case at all — just translate naturally.
4. **Character limits**: UI labels on small buttons are tight. Prefer concise translations. For Asian languages, fewer characters are needed since they're ideographic.
5. **Technical terms**: "imghost", "App Store", "Keychain", "URL", "ZIP", "EULA", "Pro", "iCloud", "Finder", "Safari" — leave these untranslated.
6. **Placeholders like `{url}` and `{filename}`** in the custom link format section — leave these verbatim.

---

## Reference: Completed Spanish Example

The Spanish file at `frontend/imghost/imghost/es.lproj/Localizable.strings` is a complete reference for the expected style and structure. Use it as a template — translate its values into your language.

The Japanese file at `frontend/imghost/imghost/ja.lproj/Localizable.strings` is a second reference showing how Asian/non-Latin scripts are handled.

---

## Full English Source — iOS App (`imghost` target)

Translate every value on the right side of `=`. Copy this file verbatim and replace only the right-hand values.

```
/* =========================================================
   imghost — iOS App  /  {YOUR LANGUAGE}
   ========================================================= */

// MARK: - Common Buttons
"button.ok" = "OK";
"button.cancel" = "Cancel";
"button.done" = "Done";
"button.retry" = "Retry";
"button.close" = "Close";
"button.save" = "Save";
"button.delete" = "Delete";
"button.sign_in" = "Sign In";
"button.sign_out" = "Sign Out";
"button.upload" = "Upload";
"button.next" = "NEXT";
"button.skip" = "SKIP";
"button.start" = "START";

// MARK: - Common States
"state.loading" = "Loading";
"state.uploading" = "UPLOADING";
"state.preparing" = "Preparing";

// MARK: - Common Labels
"label.verified" = "✓ VERIFIED";
"label.default" = "DEFAULT";
"label.required_marker" = "*";
"label.copied" = "✓";

// MARK: - Auth — Login
"auth.login.title" = "SIGN\nIN";
"auth.login.subtitle" = "ACCESS YOUR IMAGES";
"auth.login.field.email" = "Email";
"auth.login.field.password" = "Password";
"auth.login.button.sign_in" = "Sign In";
"auth.login.button.forgot_password" = "Forgot Password?";
"auth.login.button.view_pro_plans" = "View Pro Plans";
"auth.login.prompt.no_account" = "NO ACCOUNT?";
"auth.login.button.create_account" = "Create One";
"auth.login.divider" = "or";
"auth.login.error.unexpected" = "An unexpected error occurred.";
"auth.login.error.invalid_apple_credential" = "Invalid Apple ID credential.";
"auth.login.error.no_identity_token" = "Could not retrieve identity token.";
"auth.login.error.apple_failed" = "Apple Sign-In failed: %@";
"auth.login.error.apple_failed_generic" = "Apple Sign-In failed. Please try again.";
"auth.login.error.apple_failed_simple" = "Apple Sign-In failed.";

// MARK: - Auth — Register
"auth.register.title" = "CREATE\nACCOUNT";
"auth.register.subtitle" = "START UPLOADING IMAGES";
"auth.register.field.email" = "Email";
"auth.register.field.password" = "Password";
"auth.register.field.confirm_password" = "Confirm Password";
"auth.register.requirement.min_chars" = "At least 8 characters";
"auth.register.requirement.passwords_match" = "Passwords match";
"auth.register.button.create_account" = "Create Account";
"auth.register.prompt.have_account" = "HAVE AN ACCOUNT?";
"auth.register.button.sign_in" = "Sign In";
"auth.register.error.unexpected" = "An unexpected error occurred.";

// MARK: - Auth — Email Verification
"auth.verify_email.title" = "VERIFY\nEMAIL";
"auth.verify_email.subtitle" = "CHECK YOUR INBOX";
"auth.verify_email.code_sent_to" = "CODE SENT TO:";
"auth.verify_email.warning_icon" = "!";
"auth.verify_email.warning_message" = "You need to verify your email before you can upload images.";
"auth.verify_email.field.code" = "Verification Code";
"auth.verify_email.button.verify" = "Verify Email";
"auth.verify_email.button.resend" = "Resend Code";
"auth.verify_email.button.sign_out" = "Sign Out";
"auth.verify_email.success.code_sent" = "Verification code sent!";
"auth.verify_email.error.unexpected" = "An unexpected error occurred.";

// MARK: - Auth — Forgot Password
"auth.forgot_password.title" = "RESET\nPASS-\nWORD";
"auth.forgot_password.subtitle.check_email" = "CHECK YOUR EMAIL";
"auth.forgot_password.subtitle.enter_email" = "ENTER YOUR EMAIL";
"auth.forgot_password.field.email" = "Email";
"auth.forgot_password.code_sent_to" = "RESET CODE SENT TO:";
"auth.forgot_password.spam_hint" = "Check your spam folder if you don't see it.";
"auth.forgot_password.button.enter_code" = "Enter Reset Code";
"auth.forgot_password.button.send_again" = "Send Again";
"auth.forgot_password.button.send_code" = "Send Reset Code";
"auth.forgot_password.error.unexpected" = "An unexpected error occurred.";

// MARK: - Auth — Reset Password
"auth.reset_password.title" = "NEW\nPASS-\nWORD";
"auth.reset_password.title.done" = "DONE";
"auth.reset_password.subtitle.enter_code" = "ENTER RESET CODE";
"auth.reset_password.subtitle.updated" = "PASSWORD UPDATED";
"auth.reset_password.success.icon" = "✓";
"auth.reset_password.success.message" = "Your password has been updated successfully.";
"auth.reset_password.field.reset_code" = "Reset Code";
"auth.reset_password.field.new_password" = "New Password";
"auth.reset_password.field.confirm_password" = "Confirm Password";
"auth.reset_password.requirement.min_chars" = "At least 8 characters";
"auth.reset_password.requirement.passwords_match" = "Passwords match";
"auth.reset_password.button.reset" = "Reset Password";
"auth.reset_password.button.back_to_sign_in" = "Back to Sign In";
"auth.reset_password.error.unexpected" = "An unexpected error occurred.";

// MARK: - Onboarding
"onboarding.page1.title" = "HOST\nYOUR\nIMAGES";
"onboarding.page1.subtitle" = "Secure cloud storage";
"onboarding.page2.title" = "SHARE\nFROM\nANYWHERE";
"onboarding.page2.subtitle" = "iOS Share Sheet integration";
"onboarding.page3.title" = "GET\nDIRECT\nLINKS";
"onboarding.page3.subtitle" = "Instant shareable URLs";
"onboarding.page4.title" = "STAY\nORGAN-\nIZED";
"onboarding.page4.subtitle" = "All uploads in one place";
"onboarding.button.skip" = "SKIP";
"onboarding.button.next" = "NEXT";
"onboarding.button.start" = "START";
"onboarding.page_indicator" = "%d/%d";

// MARK: - Upload View
"upload.title" = "UPLOAD";
"upload.drop_zone.title" = "UPLOAD\nFILE";
"upload.drop_zone.subtitle" = "Images, videos, documents, and more";
"upload.source.photo_library" = "Photo Library";
"upload.source.browse_files" = "Browse Files";
"upload.confirm.file" = "Upload \"%@\"?";
"upload.confirm.photo" = "Upload selected photo?";
"upload.confirm.resolution" = "Resolution: %@";
"upload.confirm.button.upload" = "Upload";
"upload.confirm.button.cancel" = "Cancel";
"upload.progress.title" = "UPLOADING";
"upload.progress.cancel" = "Cancel";
"upload.success.title" = "UPLOADED";
"upload.success.link_copied" = "Link copied to clipboard";
"upload.success.hold_to_copy" = "Hold to copy";
"upload.success.copied_feedback" = "Copied!";
"upload.success.button.upload_another" = "Upload Another";
"upload.failure.title" = "UPLOAD FAILED";
"upload.failure.button.retry" = "Retry";
"upload.failure.button.cancel" = "Cancel";

// MARK: - History View
"history.title" = "MEDIA";
"history.empty.title" = "NO\nMEDIA\nYET";
"history.empty.subtitle.upload" = "Upload files to get started.";
"history.empty.subtitle.sync" = "Your uploads will appear here.";
"history.error.title" = "Something went wrong";
"history.error.button.retry" = "Retry";

// MARK: - Upload Detail View
"detail.section.image_url" = "Image URL";
"detail.section.details" = "Details";
"detail.label.uploaded" = "Uploaded";
"detail.label.original_file" = "Original File";
"detail.label.id" = "ID";
"detail.alert.delete.title" = "Delete Image";
"detail.alert.delete.button.confirm" = "Delete from Server";
"detail.alert.delete.button.cancel" = "Cancel";
"detail.alert.delete.message" = "This will permanently delete the image from the server. This action cannot be undone.";
"detail.button.share" = "SHARE";
"detail.button.copy" = "COPY";
"detail.button.copied" = "COPIED";
"detail.button.open" = "OPEN";
"detail.button.delete" = "DELETE";
"detail.button.delete_deleting" = "...";
"detail.copy_button.label" = "COPY";
"detail.copy_button.copied" = "✓";

// MARK: - Photo Grid
"photogrid.button.cancel" = "CANCEL";
"photogrid.alert.delete.title" = "Delete %d file?";
"photogrid.alert.delete.title_plural" = "Delete %d files?";
"photogrid.alert.delete.button.confirm" = "Delete";
"photogrid.alert.delete.button.cancel" = "Cancel";
"photogrid.alert.delete.message" = "This will permanently delete the selected files from the server.";
"photogrid.date.today" = "Today";
"photogrid.date.yesterday" = "Yesterday";
"photogrid.select_indicator" = "✓";

// MARK: - Settings View
"settings.title" = "SETTINGS";
"settings.subtitle" = "ACCOUNT & PREFERENCES";
"settings.section.account" = "Account";
"settings.account.email_verified" = "✓ VERIFIED";
"settings.section.storage" = "Storage";
"settings.storage.separator" = "/";
"settings.storage.percent_format" = "%.2f%%";
"settings.subscription.button.upgrade" = "Upgrade to Pro";
"settings.subscription.button.subscribe" = "Subscribe to Pro";
"settings.section.upload" = "Upload";
"settings.upload.label.resolution" = "DEFAULT RESOLUTION";
"settings.upload.label.default_badge" = "DEFAULT";
"settings.upload.hint" = "Lower quality = smaller files, faster uploads";
"settings.upload.label.behavior" = "BEHAVIOR";
"settings.upload.toggle.confirm_label" = "Confirm before uploading";
"settings.upload.toggle.confirm_hint" = "Ask for confirmation before each upload starts";
"settings.section.link_format" = "Link Format";
"settings.link_format.variables_label" = "Variables:";
"settings.link_format.var.url" = "{url}";
"settings.link_format.var.filename" = "{filename}";
"settings.link_format.button.edit_custom" = "EDIT CUSTOM FORMAT";
"settings.section.actions" = "Actions";
"settings.action.clear_history.title" = "Clear Upload History";
"settings.action.clear_history.subtitle" = "Remove local history only";
"settings.action.export.title" = "Export All Images";
"settings.action.export.subtitle" = "Download as ZIP archive";
"settings.action.delete_account.title" = "Delete Account";
"settings.action.delete_account.subtitle" = "Permanently delete all data";
"settings.section.legal" = "Legal";
"settings.legal.terms" = "Terms of Use (EULA)";
"settings.legal.privacy" = "Privacy Policy";
"settings.button.sign_out" = "Sign Out";
"settings.alert.ok" = "OK";
"settings.alert.clear_history.title" = "Clear History";
"settings.alert.clear_history.button.confirm" = "Clear All History";
"settings.alert.clear_history.button.cancel" = "Cancel";
"settings.alert.clear_history.message" = "This will remove all upload history from this device. Images on the server will not be affected.";
"settings.alert.delete_account.title" = "Delete Account";
"settings.alert.delete_account.button.confirm" = "Delete Account";
"settings.alert.delete_account.button.cancel" = "Cancel";
"settings.alert.delete_account.message" = "This will permanently delete your account and all your uploaded images. This action cannot be undone.";
"settings.success.history_cleared.title" = "History Cleared";
"settings.success.history_cleared.message" = "All upload history has been removed.";
"settings.error.title" = "Error";
"settings.error.load_account" = "Failed to load account info: %@";
"settings.error.clear_history" = "Failed to clear history: %@";
"settings.error.delete_account" = "Failed to delete account: %@";
"settings.custom_format.title" = "CUSTOM\nFORMAT";
"settings.custom_format.description" = "Define your own link template";
"settings.custom_format.label.template" = "TEMPLATE";
"settings.custom_format.placeholder" = "Enter template...";
"settings.custom_format.label.variables" = "AVAILABLE VARIABLES";
"settings.custom_format.var.url" = "{url}";
"settings.custom_format.var.url.desc" = "- The image URL";
"settings.custom_format.var.filename" = "{filename}";
"settings.custom_format.var.filename.desc" = "- Original filename";
"settings.custom_format.label.preview" = "PREVIEW";
"settings.custom_format.button.save" = "Save Format";
"settings.custom_format.button.cancel" = "CANCEL";
"settings.export.title" = "EXPORT";
"settings.export.description" = "Create a ZIP archive of all your uploaded images.";
"settings.export.button.start" = "Start Export";
"settings.export.state.starting" = "Starting";
"settings.export.state.exporting" = "EXPORTING IMAGES";
"settings.export.state.downloading" = "DOWNLOADING ARCHIVE";
"settings.export.state.complete.icon" = "✓";
"settings.export.state.complete.title" = "EXPORT COMPLETE";
"settings.export.state.complete.button.save_photos" = "Save to Photos";
"settings.export.state.complete.button.save_files" = "Save to Files";
"settings.export.state.complete.button.done" = "Done";
"settings.export.state.saving_photos" = "SAVING TO PHOTOS";
"settings.export.state.saved_photos.icon" = "✓";
"settings.export.state.saved_photos.title" = "SAVED TO PHOTOS";
"settings.export.state.saved_photos.message" = "%d images saved to your photo library";
"settings.export.state.saved_photos.button.done" = "Done";
"settings.export.state.failed.icon" = "✕";
"settings.export.state.failed.title" = "EXPORT FAILED";
"settings.export.state.failed.button.retry" = "Try Again";
"settings.export.state.failed.button.cancel" = "Cancel";
"settings.export.button.cancel" = "Cancel";
"settings.export.progress_format" = "%d%%";

// MARK: - Paywall / Subscription
"paywall.title.unlock" = "UNLOCK";
"paywall.title.pro" = "PRO";
"paywall.title.trial" = "7-DAY FREE TRIAL";
"paywall.section.features" = "WHAT YOU GET";
"paywall.feature.file_size.title" = "500MB File Size";
"paywall.feature.file_size.desc" = "Upload large files, videos, and more";
"paywall.feature.storage.title" = "10GB Storage";
"paywall.feature.storage.desc" = "Pro storage limit during trial";
"paywall.feature.sharing.title" = "Fast Sharing";
"paywall.feature.sharing.desc" = "Instant links for your images";
"paywall.feature.private.title" = "Private by Default";
"paywall.feature.private.desc" = "Secure, encrypted storage";
"paywall.section.plans" = "CHOOSE YOUR PLAN";
"paywall.error.loading" = "Unable to load subscription options";
"paywall.button.retry" = "Retry";
"paywall.badge.save" = "SAVE 30%";
"paywall.button.start_trial" = "Start Free Trial";
"paywall.button.restore" = "Restore Purchases";
"paywall.price.per_month_format" = "%@/mo";
"paywall.price.per_month_fallback" = "/month";
"paywall.error.alert.title" = "Error";
"paywall.error.alert.button.ok" = "OK";
"paywall.error.alert.message_fallback" = "An error occurred";
"paywall.legal.renewal_notice" = "After your 7-day free trial, your subscription will automatically renew at the selected price unless cancelled at least 24 hours before the end of the trial period. Payment will be charged to your Apple ID account at confirmation of purchase. Your subscription automatically renews unless auto-renew is turned off at least 24 hours before the end of the current period. You can manage and cancel your subscriptions by going to your App Store account settings after purchase.";
"paywall.legal.separator" = "|";
"paywall.legal.button.terms" = "Terms";
"paywall.legal.button.privacy" = "Privacy";

// MARK: - Subscription Status
"subscription.title" = "SUBSCRIPTION";
"subscription.section.current_plan" = "CURRENT PLAN";
"subscription.button.manage" = "Manage Subscription";
"subscription.plan.trial" = "PRO TRIAL";
"subscription.plan.active" = "PRO";
"subscription.plan.cancelled" = "PRO (CANCELLED)";
"subscription.plan.free" = "FREE";
"subscription.badge.trial" = "TRIAL";
"subscription.badge.active" = "ACTIVE";
"subscription.badge.cancelled" = "CANCELLED";
"subscription.badge.expired" = "EXPIRED";
"subscription.trial.ends_tomorrow" = "Trial ends tomorrow";
"subscription.trial.ends_in_days" = "Trial ends in %d days";
"subscription.renews_on" = "Renews on %@";
"subscription.expires_on" = "Expires on %@";
"subscription.access_until" = "Access until %@";
"subscription.expired_message" = "Your subscription has expired";

// MARK: - Error Messages
"error.not_configured.description" = "App not configured. Please set up the backend URL and token in settings.";
"error.invalid_url.description" = "Invalid backend URL. Please check your settings.";
"error.invalid_url.recovery" = "Make sure the URL starts with https:// and is a valid web address.";
"error.upload_failed.with_message" = "Upload failed (%d): %@";
"error.upload_failed.status_only" = "Upload failed with status code %d";
"error.network.description" = "Network error: %@";
"error.invalid_response.description" = "Invalid response from server";
"error.keychain.description" = "Keychain error: %d";
"error.file_system.description" = "File system error: %@";
"error.image_processing.description" = "Failed to process image";
"error.delete_failed.with_message" = "Delete failed (%d): %@";
"error.delete_failed.status_only" = "Delete failed with status code %d";
"error.email_not_verified.description" = "Please verify your email before uploading images.";
"error.subscription_required.description" = "An active subscription is required to upload files.";
"error.not_configured.recovery" = "Open the imghost app and configure your backend URL and upload token.";
"error.upload_failed.recovery" = "Check your internet connection and try again. If the problem persists, verify your upload token.";
"error.network.recovery" = "Check your internet connection and try again.";
"error.invalid_response.recovery" = "The server returned an unexpected response. Please try again later.";
"error.keychain.recovery" = "Try removing and re-entering your upload token in settings.";
"error.file_system.recovery" = "Try restarting the app. If the problem persists, reinstall the app.";
"error.image_processing.recovery" = "The image may be corrupted or in an unsupported format.";
"error.delete_failed.recovery" = "The image may have already been deleted, or your token may not have delete permissions.";
"error.email_not_verified.recovery" = "Open the imghost app and verify your email address to enable uploads.";
"error.subscription_required.recovery" = "Subscribe to imghost Pro to unlock uploads and storage.";
```

---

## Mac-only Additional Keys

The `imghostMac` target file must include all the iOS keys above **plus** these Mac-specific keys. Append them at the bottom of the `imghostMac` file:

```
// MARK: - Mac Auth Login
"auth.login.app_name" = "IMG\nHOST";
"auth.login.tagline" = "SECURE IMAGE HOSTING";
"auth.login.section.sign_in" = "SIGN IN";
"auth.login.section.hint" = "Enter your credentials";
"auth.login.button.create_account" = "CREATE ACCOUNT";
"auth.login.button.forgot_password" = "FORGOT PASSWORD";
"auth.login.error.no_apple_credential" = "Failed to get Apple credentials";

// MARK: - Mac Auth Register
"auth.register.sheet.title" = "CREATE ACCOUNT";
"auth.register.prompt.have_account" = "ALREADY HAVE AN ACCOUNT? SIGN IN";

// MARK: - Mac Auth Email Verification
"auth.verify_email.button.verify" = "VERIFY EMAIL";
"auth.verify_email.button.resend" = "RESEND CODE";
"auth.verify_email.button.sign_out" = "SIGN OUT";

// MARK: - Mac Auth Reset Password
"auth.forgot_password.sheet.title" = "RESET PASSWORD";
"auth.forgot_password.button.send_code" = "SEND RESET CODE";
"auth.forgot_password.button.enter_code" = "ENTER RESET CODE";
"auth.forgot_password.button.send_again" = "SEND AGAIN";
"auth.reset_password.button.reset" = "RESET PASSWORD";
"auth.reset_password.success.title" = "PASSWORD UPDATED";
"auth.reset_password.success.message" = "You can now sign in with your new password.";
"auth.reset_password.success.button.sign_in" = "BACK TO SIGN IN";

// MARK: - Mac Onboarding (5 pages, replaces iOS page 3+4)
"onboarding.page3.title" = "ALLOW\nACCESS";
"onboarding.page3.subtitle" = "macOS will ask to access shared files — this lets imghost read files you share from other apps like Finder or Safari";
"onboarding.page4.title" = "GET DIRECT\nLINKS";
"onboarding.page4.subtitle" = "Instant shareable URLs";
"onboarding.page5.title" = "DRAG &\nDROP";
"onboarding.page5.subtitle" = "Upload files effortlessly";

// MARK: - Mac Settings
"settings.section.subscription" = "Subscription";
"settings.subscription.days_remaining" = "%d days remaining";
"settings.subscription.button.manage" = "MANAGE SUBSCRIPTION";
"settings.badge.trial" = "TRIAL";
"settings.badge.active" = "ACTIVE";
"settings.badge.cancelled" = "CANCELLED";
"settings.badge.expired" = "EXPIRED";
"settings.storage.of_limit" = "of %@";
"settings.storage.percent_format" = "%.0f%%";
"settings.storage.file_count" = "%d files";
"settings.section.link_format.subtitle" = "Format used when copying links";
"settings.link_format.custom_field" = "Custom Template";
"settings.section.upload.subtitle" = "Default behavior for all uploads";
"settings.section.data" = "Data";
"settings.data.button.export" = "EXPORT ALL DATA";
"settings.section.danger" = "Danger Zone";
"settings.danger.button.delete_account" = "DELETE ACCOUNT";
"settings.danger.button.deleting" = "DELETING...";
"settings.account.status.verified" = "VERIFIED";
"settings.account.status.unverified" = "UNVERIFIED";
"settings.account.button.sign_out" = "SIGN OUT";

// MARK: - Mac Media View
"media.title" = "MEDIA";
"media.search.placeholder" = "Search...";
"media.label.quality" = "QUALITY";
"media.button.upload.label" = "UPLOAD";
"media.button.sync.help" = "Sync images from server";
"media.button.upload.help" = "Upload files (or drag & drop, or ⌘V to paste)";
"media.file_count" = "%d";
"media.upload.progress.title" = "UPLOADING";
"media.upload.progress.percent" = "%d%%";
"media.upload.progress.cancel" = "CANCEL";
"media.drop_zone.title" = "DROP FILES HERE";
"media.drop_zone.subtitle" = "or click Upload to browse";
"media.drop_zone.hint" = "Images, videos, and files up to 500MB";
"media.clipboard.hint" = "to paste from clipboard";
"media.drag_overlay.title" = "DROP TO UPLOAD";
"media.loading" = "Loading";
"media.banner.subscription_required" = "Subscription required to upload";
"media.banner.upload_success_singular" = "%d file uploaded — link copied";
"media.banner.upload_success_plural" = "%d files uploaded — links copied";
"media.banner.upload_failed_singular" = "%d upload failed";
"media.banner.upload_failed_plural" = "%d uploads failed";
"media.banner.upload_partial" = "%d uploaded, %d failed";

// MARK: - Mac History View
"history.title" = "HISTORY";
"history.search.placeholder" = "Search...";
"history.loading" = "Loading";
"history.empty.title" = "No uploads yet";
"history.empty.subtitle" = "Upload your first image to get started";
"history.search.empty.title" = "No results";
"history.search.empty.subtitle" = "Try a different search term";
"history.file_count" = "%d";
"history.detail.placeholder" = "SELECT AN IMAGE";

// MARK: - Mac Upload View
"upload.confirm.files_plural" = "Upload %d files?";
"upload.confirm.clipboard_single" = "Upload clipboard image?";
"upload.confirm.clipboard_plural" = "Upload %d items from clipboard?";
"upload.label.resolution" = "RESOLUTION";
"upload.drop_zone.subtitle" = "or click to browse";
"upload.clipboard.hint" = "to paste from clipboard";
"upload.success.button.upload_more" = "UPLOAD MORE";
"upload.success.button.copy_all" = "COPY ALL LINKS";

// MARK: - Mac Upload Detail View
"detail.label.filename" = "FILENAME";
"detail.label.link_format" = "LINK FORMAT";
"detail.button.copy_link" = "COPY LINK";
"detail.button.copied" = "COPIED";
"detail.button.share" = "SHARE";

// MARK: - Mac Paywall
"paywall.feature.file_size" = "500MB Files";
"paywall.feature.storage" = "10GB Storage";
"paywall.feature.sharing" = "Fast Sharing";
"paywall.feature.private" = "Private";

// MARK: - Menu Bar
"menubar.app_name" = "IMGHOST";
"menubar.status.online" = "ONLINE";
"menubar.button.upload.label" = "UPLOAD";
"menubar.button.paste.label" = "PASTE";
"menubar.button.sync.label" = "SYNC";
"menubar.upload.filename_fallback" = "Uploading...";
"menubar.upload.progress_percent" = "%d%%";
"menubar.section.recent" = "RECENT";
"menubar.recent.empty" = "NO UPLOADS YET";
"menubar.footer.open_app" = "Open App";
"menubar.footer.settings" = "Settings";
"menubar.footer.quit" = "Quit";
"menubar.not_signed_in.title" = "NOT SIGNED IN";
"menubar.not_signed_in.message" = "Open the app to sign in";
"menubar.not_signed_in.button.open" = "OPEN IMGHOST";
"menubar.upload_panel.title" = "Upload Image";
"menubar.confirm.file" = "Upload \"%@\"?";
"menubar.confirm.clipboard" = "Upload clipboard image?";
"menubar.confirm.resolution" = "Resolution: %@";
"menubar.confirm.button.upload" = "Upload";
"menubar.confirm.button.cancel" = "Cancel";
"menubar.status.no_clipboard_image" = "No image in clipboard";
"menubar.status.uploaded_link_copied" = "Uploaded — link copied";
"menubar.status.upload_failed" = "Upload failed";
"menubar.status.synced" = "Synced";
"menubar.time.just_now" = "just now";
"menubar.time.minutes_ago" = "%dm ago";
"menubar.time.hours_ago" = "%dh ago";
"menubar.time.days_ago" = "%dd ago";
"menubar.recent_item.filename_fallback" = "image";
```

---

## Full English Source — iOS Share Extension (`ShareExtension` target)

```
/* =========================================================
   imghost — iOS Share Extension  /  {YOUR LANGUAGE}
   ========================================================= */

"button.cancel" = "CANCEL";
"button.done" = "DONE";
"button.retry" = "RETRY";
"button.open_app" = "OPEN APP";
"share.state.loading" = "LOADING...";
"share.state.uploading" = "UPLOADING";
"share.preview.item_count_singular" = "%d ITEM";
"share.preview.item_count_plural" = "%d ITEMS";
"share.preview.item_count_label_singular" = "%d ITEM";
"share.preview.item_count_label_plural" = "%d ITEMS";
"share.preview.total_size" = "%.1f MB TOTAL";
"share.preview.warning.exceeds_limit" = "SOME FILES EXCEED 500MB LIMIT";
"share.preview.item.too_large" = "TOO LARGE";
"share.preview.item.size_format" = "%.1fMB";
"share.preview.quality_label" = "IMAGE QUALITY";
"share.preview.button.upload_singular" = "UPLOAD %d ITEM";
"share.preview.button.upload_plural" = "UPLOAD %d ITEMS";
"share.preview.storage_warning" = "EXCEEDS STORAGE (%@)";
"share.preview.file_too_large" = "File too large";
"share.quality.original" = "Full";
"share.quality.high" = "High";
"share.quality.medium" = "Med";
"share.quality.low" = "Low";
"share.quality.very_low" = "Min";
"share.upload.progress_count" = "%d/%d";
"share.upload.progress_percent" = "%d%%";
"share.upload.button.cancel" = "CANCEL";
"share.result.partial" = "%d UPLOADED, %d FAILED";
"share.result.copied_single" = "COPIED TO CLIPBOARD";
"share.result.copied_plural" = "%d LINKS COPIED";
"share.result.links_count" = "%d LINKS";
"share.result.button.done" = "DONE";
"share.result.item.size_format" = "%.1f MB";
"share.failed.title" = "UPLOAD FAILED";
"share.failed.button.retry" = "RETRY";
"share.failed.button.cancel" = "CANCEL";
"share.not_logged_in.title" = "NOT LOGGED IN";
"share.not_logged_in.message" = "OPEN THE IMGHOST APP TO LOG IN";
"share.not_logged_in.button.open_app" = "OPEN APP";
"share.not_logged_in.button.cancel" = "CANCEL";
"share.session_expired.title" = "SESSION EXPIRED";
"share.session_expired.message" = "PLEASE LOG IN AGAIN TO CONTINUE UPLOADING";
"share.session_expired.button.open_app" = "OPEN APP TO LOGIN";
"share.session_expired.button.cancel" = "CANCEL";
"share.storage_full.title" = "STORAGE FULL";
"share.storage_full.usage_format" = "%@ / %@";
"share.storage_full.need_more" = "NEED %.1f MB MORE";
"share.storage_full.cta" = "DELETE FILES OR UPGRADE YOUR PLAN";
"share.storage_full.button.done" = "DONE";
"error.not_configured.description" = "App not configured. Please set up the backend URL and token in settings.";
"error.invalid_url.description" = "Invalid backend URL. Please check your settings.";
"error.invalid_url.recovery" = "Make sure the URL starts with https:// and is a valid web address.";
"error.upload_failed.with_message" = "Upload failed (%d): %@";
"error.upload_failed.status_only" = "Upload failed with status code %d";
"error.network.description" = "Network error: %@";
"error.invalid_response.description" = "Invalid response from server";
"error.keychain.description" = "Keychain error: %d";
"error.file_system.description" = "File system error: %@";
"error.image_processing.description" = "Failed to process image";
"error.delete_failed.with_message" = "Delete failed (%d): %@";
"error.delete_failed.status_only" = "Delete failed with status code %d";
"error.email_not_verified.description" = "Please verify your email before uploading images.";
"error.subscription_required.description" = "An active subscription is required to upload files.";
"error.not_configured.recovery" = "Open the imghost app and configure your backend URL and upload token.";
"error.upload_failed.recovery" = "Check your internet connection and try again. If the problem persists, verify your upload token.";
"error.network.recovery" = "Check your internet connection and try again.";
"error.invalid_response.recovery" = "The server returned an unexpected response. Please try again later.";
"error.keychain.recovery" = "Try removing and re-entering your upload token in settings.";
"error.file_system.recovery" = "Try restarting the app. If the problem persists, reinstall the app.";
"error.image_processing.recovery" = "The image may be corrupted or in an unsupported format.";
"error.delete_failed.recovery" = "The image may have already been deleted, or your token may not have delete permissions.";
"error.email_not_verified.recovery" = "Open the imghost app and verify your email address to enable uploads.";
"error.subscription_required.recovery" = "Subscribe to imghost Pro to unlock uploads and storage.";
```

---

## Full English Source — macOS Share Extension (`MacShareExtension` target)

```
/* =========================================================
   imghost — macOS Share Extension  /  {YOUR LANGUAGE}
   ========================================================= */

"button.cancel" = "CANCEL";
"button.close" = "CLOSE";
"button.continue" = "CONTINUE";
"button.retry" = "RETRY";
"button.done" = "DONE";
"button.upload" = "UPLOAD";
"button.copy_all" = "COPY ALL";
"share.app_name" = "IMGHOST";
"share.state.loading" = "Loading files...";
"share.state.uploading" = "UPLOADING";
"share.upload.progress_percent" = "%d%%";
"share.upload.status.starting" = "Starting upload...";
"share.upload.status.in_progress" = "Uploading %@ (%d/%d)";
"share.upload.status.preparing" = "Preparing...";
"share.error.title" = "ERROR";
"share.error.button.retry" = "RETRY";
"share.error.button.close" = "CLOSE";
"share.error.no_content" = "No content received from share sheet. The extension context had no input items.";
"share.error.failed_to_load" = "Failed to load shared files:\n%@";
"share.error.not_signed_in_upload" = "Not signed in. Open the imghost app and sign in first.";
"share.permission.title" = "PERMISSION NEEDED";
"share.permission.prompt" = "macOS will ask imghost to \"access data from other apps.\"";
"share.permission.explanation" = "This is required so imghost can read the files you share from Finder, Safari, and other apps. Without this permission, the share extension can't upload your files.";
"share.permission.privacy_note" = "Your files are only used for uploading — nothing is stored locally.";
"share.permission.button.cancel" = "CANCEL";
"share.permission.button.continue" = "CONTINUE";
"share.not_signed_in.title" = "NOT SIGNED IN";
"share.not_signed_in.message" = "Open the imghost app and sign in to enable uploads from the share sheet.";
"share.not_signed_in.button.close" = "CLOSE";
"share.no_files.title" = "NO FILES FOUND";
"share.no_files.message" = "No compatible files were found in the shared content. Try sharing an image or file directly.";
"share.no_files.button.close" = "CLOSE";
"share.preview.quality_label" = "QUALITY";
"share.preview.file_count_singular" = "%d file";
"share.preview.file_count_plural" = "%d files";
"share.preview.button.cancel" = "CANCEL";
"share.preview.button.upload" = "UPLOAD";
"share.results.uploaded_count" = "%d/%d uploaded";
"share.results.failed_count" = "%d failed";
"share.results.button.copy_all" = "COPY ALL";
"share.results.button.done" = "DONE";
"share.error.description.not_signed_in" = "Not signed in. Open imghost app to sign in.";
"share.error.description.invalid_url" = "Invalid upload URL. Check backend configuration.";
"share.error.description.invalid_response" = "Invalid response from server.";
"share.error.description.upload_failed" = "Upload failed (HTTP %d): %@";
"share.error.description.network" = "Network error: %@";
"share.error.description.subscription_required" = "Subscription required. Upgrade in the imghost app.";
"share.error.description.email_not_verified" = "Email verification required. Check your email.";
"share.error.description.keychain" = "Keychain error (status %d). Try signing in again.";
"share.error.description.file_system" = "File error: %@";
"share.error.description.image_processing" = "Failed to process image. File may be corrupted.";
"share.error.description.delete_failed" = "Delete failed (HTTP %d): %@";
"share.error.description.no_details" = "No details";
"error.not_configured.description" = "App not configured. Please set up the backend URL and token in settings.";
"error.invalid_url.description" = "Invalid backend URL. Please check your settings.";
"error.invalid_url.recovery" = "Make sure the URL starts with https:// and is a valid web address.";
"error.upload_failed.with_message" = "Upload failed (%d): %@";
"error.upload_failed.status_only" = "Upload failed with status code %d";
"error.network.description" = "Network error: %@";
"error.invalid_response.description" = "Invalid response from server";
"error.keychain.description" = "Keychain error: %d";
"error.file_system.description" = "File system error: %@";
"error.image_processing.description" = "Failed to process image";
"error.delete_failed.with_message" = "Delete failed (%d): %@";
"error.delete_failed.status_only" = "Delete failed with status code %d";
"error.email_not_verified.description" = "Please verify your email before uploading images.";
"error.subscription_required.description" = "An active subscription is required to upload files.";
"error.not_configured.recovery" = "Open the imghost app and configure your backend URL and upload token.";
"error.upload_failed.recovery" = "Check your internet connection and try again. If the problem persists, verify your upload token.";
"error.network.recovery" = "Check your internet connection and try again.";
"error.invalid_response.recovery" = "The server returned an unexpected response. Please try again later.";
"error.keychain.recovery" = "Try removing and re-entering your upload token in settings.";
"error.file_system.recovery" = "Try restarting the app. If the problem persists, reinstall the app.";
"error.image_processing.recovery" = "The image may be corrupted or in an unsupported format.";
"error.delete_failed.recovery" = "The image may have already been deleted, or your token may not have delete permissions.";
"error.email_not_verified.recovery" = "Open the imghost app and verify your email address to enable uploads.";
"error.subscription_required.recovery" = "Subscribe to imghost Pro to unlock uploads and storage.";
```

---

## Execution Checklist

- [ ] Created `imghost/{LANG}.lproj/Localizable.strings` — iOS app (all keys)
- [ ] Created `imghostMac/{LANG}.lproj/Localizable.strings` — macOS app (all iOS keys + Mac-only section)
- [ ] Created `ShareExtension/{LANG}.lproj/Localizable.strings` — iOS share extension
- [ ] Created `MacShareExtension/{LANG}.lproj/Localizable.strings` — macOS share extension
- [ ] Ran the Ruby script to register in `project.pbxproj`
- [ ] Verified `{LANG}` appears in `knownRegions` in `project.pbxproj`
- [ ] Committed and pushed

## Git Conflict Strategy

Multiple agents commit simultaneously. Use this pattern:

```bash
cd /Users/codybontecou/dev/imghost
git pull --rebase   # pull latest before committing
git add frontend/imghost/imghost/{LANG}.lproj/ \
        frontend/imghost/imghostMac/{LANG}.lproj/ \
        frontend/imghost/ShareExtension/{LANG}.lproj/ \
        frontend/imghost/MacShareExtension/{LANG}.lproj/ \
        frontend/imghost/imghost.xcodeproj/project.pbxproj
git commit -m "i18n: add {LANGUAGE_NAME} ({LANG}) translations"
git pull --rebase   # resolve any conflicts from other agents
git push
```

If `project.pbxproj` has a merge conflict, it almost certainly means two agents both added different languages to `knownRegions` at the same time. Resolve it by keeping ALL entries from both sides. The conflict will look like:

```
<<<<<<< HEAD
				ja,
				es,
=======
				de,
>>>>>>> ...
```

Resolve to:
```
				ja,
				es,
				de,
```

Then `git add project.pbxproj && git rebase --continue && git push`.
