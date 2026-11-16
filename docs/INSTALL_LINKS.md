# Install links

An install link is a symlink from a folder in a checkout into a folder that loads it. The main
case is a WordPress plugin or theme you develop in `~/Projects` and test in a Local site: link it
once, and every site runs the code you are editing. No copies to keep in sync.

## In the app

A product whose checkout has a WordPress plugin header (or a theme's `style.css`) shows an
**Install links** card on its Development tab:

- **Link into Site**: the Local sites on this Mac that do not have it yet. One click creates
  `wp-content/plugins/<folder>` (or `themes/`) as a symlink to the checkout.
- **Already linked by hand**: symlinks you made yourself that point into the checkout. Track
  them to see their state here.
- **Has its own copy**: a site with a real folder of the same name, with both versions. Replace
  Copy with Link moves the copy to `wp-content/forgedeck-backups/<name>-<time>`, outside plugins
  and themes so WordPress does not load it, then links. If the link fails, the copy is put back.
- **Link into Folder…**: any other destination, for any product.

Each tracked link shows its state: Linked, Not linked, Broken link, Points elsewhere, A copy is in
the way, Destination missing, or Source missing.

## From a terminal

```
forgedeck links <product>                 # tracked links, hand-made links, and sites to link into
forgedeck link <product> --site <site>    # link the plugin or theme into a Local site
forgedeck link <product> --site <site> --remove
```

## Rules

- A symlink, never a Finder alias. PHP and WordPress follow symlinks and ignore aliases.
  WordPress has supported symlinked plugins since 3.9.
- Never overwrite. If anything is at the destination, nothing changes.
- Unlinking removes only a symlink that points at the checkout. The checkout is never touched.
- Sites are found by their folders (`wp-content/plugins` and `wp-includes`) under `~/Local Sites`,
  `~/Sites`, `~/Studio`, and the code folders in Settings. `wp-config.php` is never opened.
- Local folders only. Nothing touches a remote server.

## Limits

- **Docker setups** (wp-env, DDEV, Docker Compose) mount specific folders into a container. A link
  that points outside the mounted folders is invisible inside it. Local runs PHP on the Mac, so
  links work there.
- **Plugins with a build step**: link the build output folder instead of the repository root.
  The model stores a subfolder for each link, but the app's buttons link the checkout itself for
  now. Use Link into Folder after creating the link by hand, or Track a hand-made link.
- Deactivate a plugin before replacing its copy if the site is running.
