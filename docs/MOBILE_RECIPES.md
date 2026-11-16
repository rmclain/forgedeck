# Mobile app recipes

Recipes live on a product's **Actions** tab. A recipe is a reviewed command, or a short list of
commands, that runs in one checkout. For a mobile app, ForgeDeck can suggest the usual ones.

## Suggested recipes

Press **Suggest Mobile Recipes** on the Actions tab (it appears when a checkout has a Capacitor
config or an Xcode project). ForgeDeck reads the project and the simulators and emulators on this
Mac, and adds recipes marked Suggested. Nothing runs until you approve a recipe.

For a Capacitor app (Capacitor 8, `ios/App/App.xcodeproj`, an Android
project, and `build:app`, `ios`, and `android` scripts in package.json):

| Recipe | Steps |
| --- | --- |
| Open iOS Project in Xcode | `npm run ios` (the project's script: build www, `cap sync`, open Xcode) |
| Build and Run on iPhone 17 Pro Simulator | `npm run build:app` → `npx cap run ios --target <simulator id> --no-sync` |
| Open Android Project in Android Studio | `npm run android` |
| Build and Run on ccc pixel7 Emulator | `npm run build:app` → `npx cap run android --target ccc_pixel7 --no-sync` |

`--no-sync` is added because `build:app` already ends with `cap sync`. Without that script,
ForgeDeck uses `npm run build` (when present), then `cap sync` or `cap run`. Without a known
simulator, `cap run ios` asks which device to use, in the terminal. A plain Xcode project with no
Capacitor gets **Open in Xcode** (`open -a Xcode <project>`).

## Steps

A recipe can now hold several commands, one per line in the recipe editor. They run in order and
the first failure stops the rest. No shell is involved: each line is a program and its arguments.
In a terminal, ForgeDeck writes a small script with every word quoted; captured runs start each
step as its own process and show all output in the run log.

## Where else this could live

Recipes are stored by ForgeDeck, per Mac, because they name local simulators and checkouts. If
you want them to travel with the repository, the next step would be a `forgedeck.recipes.json`
in the repo that ForgeDeck imports as suggestions. That is not built: it would mean adding a file
to each repository.
