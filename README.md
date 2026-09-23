# Food Optimizer

A World of Warcraft Classic addon that decides which food and drink to eat for you, so your bags stay tidy.

By default it eats the food you have the **fewest** of first. That stack runs out sooner and frees up a bag slot. When two foods tie, it eats the one that restores the **least** first, and it saves your best food for later. You can also set the order yourself.

![Food Optimizer panel](screenshots/panel.png)

## Features

- **Scans all your bags** and finds every food (restores health over time) and drink (restores mana over time). It skips potions, recipes, and food that needs a higher level than you are.
- **Smart default order:** fewest first, then lowest amount restored. It always eats from your smallest stack.
- **Your own order:** open the panel with `/fo` and move items up or down with the arrows. Your order is saved.
- **Never use an item:** untick **Use** to keep something out of rotation, such as buff food you're saving for a raid.
- **Separate food and drink**, each with its own tab, button and macro.
- **Action bar macros:** one click creates a macro. The action bar button always shows the icon, tooltip and count of what it will eat next.

![Macro on the action bar](screenshots/macro-button.png)

## Installation

1. Download or clone this repository.
2. Put the `FoodOptimizer` folder in `World of Warcraft/_classic_era_/Interface/AddOns/`.
3. Restart the game or type `/reload`.

If the addon shows as out of date, tick **Load out of date AddOns** on the character select screen. You can also update the `## Interface:` line in `FoodOptimizer.toc` to your client's version. Run `/dump select(4, GetBuildInfo())` in game to find it.

## Usage

1. Type `/fo` to open the panel.
2. Pick the **Food** or **Drink** tab and arrange the order if you want. The top item is eaten first.
3. Click **Create Food macro** or **Create Drink macro**. The macro lands on your cursor, so drop it on an action bar.
4. Press the action bar button whenever you want to eat or drink.

The addon keeps the macros up to date as your bags change. Macros can't be changed during combat, so any changes made in combat apply as soon as the fight ends.

### Slash commands

| Command | Description |
| --- | --- |
| `/fo` | Open or close the order panel |
| `/fo show` / `/fo hide` | Show or hide the small on-screen buttons |
| `/fo reset` | Move the on-screen buttons back to their default spot |

### Manual macros

If you'd rather write the macros yourself:

```
/click FoodOptimizerFoodButton
```

```
/click FoodOptimizerDrinkButton
```

## Notes

- WoW doesn't let addons use items on their own, so eating always needs a key press or click. The addon only picks *what* gets eaten.
- Items that restore both health and mana (like Conjured Mana Biscuits) show up on both tabs. Untick them on the tab you don't want them used from.
- Tooltip reading only works on English game clients.
- Built for the Classic Era client (1.15.x).
