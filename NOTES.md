# Workspace Switcher

- [x] Vim key-binds (^j/^k + ^n/^p in switcher and palette — bare j/k would type into the filter; bare j/k in the inbox)
- [x] Focus currently always starts at the top and it should start on the active workspace

# Rook Agent

- [ ] The rook agent should have more agency. Right now it does a lot of just "yours to answer".
- [ ] Improve the agent recommendation and response setup. I'm thinking something like having something on the dashboard, or a way to have a more detailed view, where Rook can display a summary of what it's replying to and why. If we dial this in, it will/should let us just run most claude code sessions "in the background" and only attach when we specifically choose to directly attach even though it's running interactive the whole time.

# Rook App

- [x] Better total cost tracking in a sort of app wide status bar with more details on the main "workspace manager" screen
- [x] Baked in claude code usage. We still track total "cost" when using a claude subscription, but we want to also keep track of remaining usage for the period for subscription accounts

# Issue Tracking

- [ ] One of the next things we should probably setup is some kind of issue tracking integration. Then the rook agent can tie into the list of issues to determine what we should work on next
