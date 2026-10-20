# MyFood

MyFood helps households plan their meals, buy what those meals need, and keep track of what they have at home. A culinary agent proposes meal plans; people confirm them.

## Language

### People and groups

**Household**:
A group of people who share one meal plan, pantry, shopping list and budget.
_Avoid_: Account, family, group

**User**:
A person's sign-in identity. A User can be a Member of several Households.
_Avoid_: Account, customer

**Member**:
A User with an active membership in a Household. A User's private dietary profile applies in every Household where that User is a Member.
_Avoid_: Participant, account user

**Owner**:
The Member who administers a Household's membership and subscription: invites and removes Members, and may cancel another Member's Planning Session. Owners have no other planning powers.
_Avoid_: Admin, head of household

### Dietary rules

**Restriction**:
A hard rule about what a Member must not eat: an allergy or a diet (vegetarian, vegan, pescatarian, celiac). It is never relaxed except by an Absence Exception.
_Avoid_: Preference, mandatory preference

**Preference**:
Soft guidance the culinary agent tries to honour: disliked ingredients, tastes, preferred brands and session intents. The agent says so when it does not honour one.
_Avoid_: Restriction, rule

**Ingredient Tag**:
A reviewed classification of a catalog ingredient (an allergen, or a diet-relevant property such as containing meat, fish, animal products or gluten). Every Restriction is expressed as a set of forbidden Ingredient Tags: vegetarian forbids meat and fish, pescatarian forbids meat, vegan forbids every animal product, celiac forbids gluten, omnivore forbids nothing, and an allergy forbids its allergen. A suggested tag (for example from AI) does not count until a reviewer accepts it.
_Avoid_: Category, label

**Nutrition Goal**:
A Household's daily range of calories and macros per standard portion. Missing it is a Deviation. A Member's private macro focus is only a Preference.
_Avoid_: Kcal target, macro goal, diet

### Planning

**Meal Plan**:
A Household's single calendar of confirmed Planned Meals. It grows with each confirmation and has no versions.
_Avoid_: Weekly plan, sub-plan, menu

**Planned Meal**:
A recipe assigned to a day and meal slot in the Meal Plan, with its portions and any guest constraints.
_Avoid_: Scheduled meal, menu item

**Planning Range**:
The consecutive, not-yet-planned days covered by one planning. Planning Ranges never overlap.
_Avoid_: Planning week, period

**Proposal**:
An unconfirmed assignment of meals for a Planning Range, shown to a Member. A Proposal is never called a plan.
_Avoid_: Draft plan, candidate plan

**Planning Session**:
The exclusive, ephemeral period in which one Member plans one Planning Range with the culinary agent. Only one Planning Session per Household can be active.
_Avoid_: Planning chat, planning conversation

**Workspace**:
The working state of a Planning Session: the current Proposal, pinned, excluded and released meals, variety cap, session brands and approved exceptions. It is discarded when the Planning Session ends.
_Avoid_: Draft, scratchpad

**Pin**:
A Member's choice to fix a recipe to a day and meal slot for the rest of a Planning Session, whether it was already proposed or newly requested. It beats the variety cap but never a Restriction.
_Avoid_: Protected meal, locked meal

**Excluded Recipe**:
A recipe a Member ruled out for the rest of a Planning Session.
_Avoid_: Blacklist, banned recipe

**Released Meal**:
A day and meal slot of the current Proposal that the next optimization may change; every other slot stays as it is. Only slots the Member mentioned are released unless the Member agrees to more. A meal the Member asked to change always gets a different recipe; "redo the whole week" releases every meal without forcing each one to change.
_Avoid_: Unlocked meal, free slot

**Stop**:
Interrupting the culinary agent's current work while keeping the Planning Session and its Workspace.
_Avoid_: Pause, abort

**Cancel**:
Ending a Planning Session without confirming: its Workspace is discarded and the Household can start a new Planning Session.
_Avoid_: Stop, leave, close

**Absence Grace**:
The 15 minutes a Planning Session, its Workspace, its last Proposal and the Household's slot are kept after its Member leaves or disconnects, also across a server restart. Nothing runs or is saved while the Member is absent; only that Member, still active in the Household, can return. When it expires the Workspace is discarded and the slot released. A restart never resets it.
_Avoid_: Timeout, idle period

**Idle Expiry**:
The end of a Planning Session whose Member stays connected but takes no action for 30 minutes while no agent work runs. Like an expired Absence Grace, the Workspace is discarded and the Household's slot released.
_Avoid_: Absence Grace, session timeout

**Spend Cap**:
The most a Planning Session may spend on the paid AI provider, in money and in cumulative tokens, across all of its turns. Stop and new messages never reset it. Separate from the Household's grocery budget.
_Avoid_: Budget, execution cap

### Recipes

**Catalog Recipe**:
A recipe shared by every Household, maintained only by the MyFood team.
_Avoid_: Public recipe, global recipe

**Household Recipe**:
A recipe private to one Household, either AI-created (saved when a confirmed Proposal used it) or user-created (dictated by a Member and saved explicitly).
_Avoid_: Custom recipe, my recipe

**Recipe Draft**:
A recipe the culinary agent built during a Planning Session that exists only in its Workspace until a confirmation saves it.
_Avoid_: Temporary recipe, generated recipe

**Recipe Origin**:
Whether a recipe is traditional, AI-created or user-created; always shown to Members.
_Avoid_: Source, author

**Recipe Version**:
An immutable state of a recipe. Editing a recipe creates a new version; Planned Meals keep the version they were confirmed with.
_Avoid_: Revision, edit

### Ingredients, products and prices

**Ingredient**:
A generic catalog item a recipe calls for, such as dried pasta. Ingredient Tags and nutrition belong to the Ingredient.
_Avoid_: Product, item

**Product**:
A specific supermarket article that covers an Ingredient, with its brand and package size. Purchases are made of Products.
_Avoid_: Ingredient, SKU, item

**Price Observation**:
The price of a Product at a supermarket, with its currency and when it was observed. It is fresh when under 24 hours old; an older one is always shown with its age. Prices are never invented.
_Avoid_: Current price, estimate

**Brand Preference**:
A Household Preference for a brand of an Ingredient, kept in household settings.
_Avoid_: Favourite brand, preferred product

**Session Brand**:
A brand chosen for an Ingredient only within one Planning Session; it lives in the Workspace.
_Avoid_: Temporary brand, chat brand

### Pantry and shopping

**Pantry**:
The stock a Household has at home. A Shopping List line enters the Pantry when it is bought.
_Avoid_: Inventory, fridge, stock

**Projected Pantry**:
The Pantry minus what is already committed to Planned Meals not yet cooked. Planning always uses the Projected Pantry.
_Avoid_: Available stock, net pantry

**Purchase**:
The priced lines, rounded up to real store packages, that a Proposal needs beyond the Projected Pantry. It is what the budget is compared against.
_Avoid_: Shopping estimate, cost, shortages

**Shopping List**:
A Household's accumulated lines to buy. Confirming a Proposal appends its Purchase without touching existing lines.
_Avoid_: Cart, shopping cart

### Approvals

**Deviation**:
A numeric goal a Proposal misses, with its exact amount: budget, a day's calories or a day's macros.
_Avoid_: Overspend, violation, relaxation

**Deviation Approval**:
A Member's single, all-or-nothing acceptance of every Deviation of one exact Proposal. Any change to the Proposal voids it. It never changes the Household's stored budget or goals.
_Avoid_: Overspend approval, waiver

**Absence Exception**:
A Member's approval to lift one specific restriction of an absent Member for specific Planned Meals. By default every Member counts as present at every meal. It never edits a profile and is never inherited when meals are reused.
_Avoid_: Attendance, present members, absence waiver
