# How Our Raffle Works (Plain English)

*A simple guide to the product flow and the choices we made—no technical jargon.*

---

## What We’re Building

We built a raffle system where:

- **Sellers** put up a prize and set the rules. They get paid only if the raffle fully sells out.
- **Buyers** buy tickets during a set time. They either win a share of the prize or get their money back if the raffle doesn’t sell out.
- **The system** runs the rules automatically. No one in the middle decides who wins or holds the money.

Everything is designed so that the outcome is clear and fair, and no single party can change the rules or the result once the raffle is set up.

---

## How a Raffle Runs (Step by Step)

### 1. Someone Creates a Raffle (The Seller)

The seller sets up the raffle by deciding:

- **What’s the prize?** (e.g. a certain amount of a token)
- **How much is one ticket?** and **How many tickets in total?**
- **When does it start and end?**
- **How many winners?** (e.g. 3 winners; the prize is split evenly among them)

The seller then locks the prize in the system. Until the raffle is over, that prize stays locked. No one can take it out except according to the rules (either to winners or back to the seller).

We also allow “creating a raffle for someone else”: another person or app can set it up, but the prize always comes from the actual seller’s account, so the seller stays in control.

---

### 2. People Buy Tickets (Buyers)

During the raffle period, anyone can buy tickets. For each purchase they choose:

- How many tickets to buy
- Who gets the tickets (themselves or someone else, e.g. a gift)

Payment is always taken from the person paying. The tickets can be assigned to a different person (e.g. you pay, your friend gets the tickets).

The system makes sure:

- The raffle is still open
- The total number of tickets isn’t exceeded
- No single account can buy more than a set maximum (so one person doesn’t dominate)

Once you buy, your money is in the raffle until it ends. Then you either win a share of the prize or get a refund.

---

### 3. The Raffle Ends and the Result Is Decided (Finalization)

When the end time is past, the raffle can be “finalized.” **Anyone** can trigger this—the seller doesn’t have to. The system then looks at one thing:

**Did every ticket get sold?**

- **If yes (full sell-out):**  
  The raffle “succeeds.” The system takes a small fee (e.g. 2%), gives the rest of the ticket money to the seller, picks the winners in a fair way, and records how much each winner gets. No one chooses the winners by hand—it’s done by the rules.

- **If no (even one ticket left unsold):**  
  The raffle “fails.” No fee is taken, no winners are picked. All buyers can get their money back, and the seller can take the prize back.

So the only question at the end is: sold out or not? Everything else (who wins, who gets paid) follows from that.

---

### 4. People Collect What They’re Owed (Settlement)

After the raffle is finalized, people don’t get paid automatically. They **claim** what they’re owed:

- **Winners** claim their share of the prize.
- **Buyers (if the raffle failed)** claim a full refund of what they paid for tickets.
- **Seller (if the raffle succeeded)** claims the ticket money (after the fee).
- **Seller (if the raffle failed)** claims the prize back.

So: the system doesn’t “send” money to anyone. It keeps a record of who is owed what, and when they’re ready they ask for it. That way we avoid problems like payments failing or getting stuck, and everyone gets their funds when they choose to collect.

---

## Why We Made These Choices

Below are the main decisions we made and the reasoning in simple terms.

---

### 1. All-or-Nothing: Either Full Sell-Out or Full Refund

**What we do:** The raffle only “succeeds” if every single ticket is sold. If one ticket is left unsold, the raffle fails and everyone gets refunds (and the seller gets the prize back).

**Why:** We wanted a single, clear rule: “Did we hit the target or not?” No grey area like “we sold 80%, so we’ll run it anyway.” That makes it easy to explain and to trust. It also encourages sellers to set a realistic price and number of tickets.

**Trade-off:** Some might prefer “run if we hit 80%.” We chose simplicity and a clear yes/no outcome.

---

### 2. One Clear Rule for “Target”

**What we do:** The “target” to succeed is always: ticket price × total number of tickets. Sellers can’t set a different target that doesn’t match.

**Why:** So there’s no confusion. “Success” always means “every ticket sold.” You can’t accidentally set things so the raffle can never succeed or so “success” means something else.

**Trade-off:** Slightly less flexibility (e.g. no “soft launch” with a lower target). We preferred clarity.

---

### 3. Only Token Payments (No “Raw” Native Currency in the Core)

**What we do:** All money in and out is in the form of tokens (like stablecoins or wrapped currency). We don’t handle the native chain currency directly in the core product.

**Why:** Supporting both “raw” currency and tokens adds a lot of edge cases and complexity. Most users can use a token version of the currency (e.g. wrapped) or a stablecoin. Keeping everything as tokens keeps the system simpler and safer to run.

**Trade-off:** Users who want to pay in the chain’s native currency need one extra step (e.g. wrap it first). We accepted that for a simpler, more reliable system.

---

### 4. You Claim Your Winnings or Refund (We Don’t Send Automatically)

**What we do:** After the raffle ends, winners and refund recipients don’t get paid automatically. They have to take an action to “claim” their share.

**Why:** Automatically sending to a long list of people can fail (e.g. some addresses can’t receive). That could block everyone or create security issues. When people claim themselves, each transfer is separate and under their control. We also avoid certain attack patterns that can happen when the system “pushes” money out.

**Trade-off:** People have to remember to claim. We think that’s acceptable and we can build reminders or simple tools for that.

---

### 5. How We Pick Winners (Fair and Automatic)

**What we do:** Winners are chosen at the moment the raffle is finalized, using a process that depends on data that’s already public and fixed (from past activity on the chain). We don’t use “future” data that could be influenced.

**Why:** We want the result to be fair and not manipulable. Using only past, fixed data means no one can change the outcome after the fact. We also cap how many winners we pick so we always have enough data to do this safely.

**Trade-off:** For very high-stakes raffles, one could use a more advanced randomness service later. We built the system so that can be added without changing the basic flow.

---

### 6. Winners Are Decided When the Raffle Ends (Not When Someone Claims)

**What we do:** As soon as we know the raffle sold out, we immediately decide who the winners are and how much each gets. We don’t wait until the first person claims.

**Why:** So there’s one clear moment when the outcome is fixed. Everyone can see who won and how much. No dependency on who claims first or in what order.

**Trade-off:** The raffle has to end when we have enough “past data” to pick winners. We set limits (e.g. max number of winners) so this is always possible in normal use.

---

### 7. The Same Person Can Win More Than Once

**What we do:** If someone bought many tickets, they can appear as a winner more than once and get multiple prize shares.

**Why:** We treat each ticket as one chance. More tickets mean more chances, including the chance to win several times. Forbidding that would complicate the rules and could make the odds less intuitive.

**Trade-off:** A single big buyer could win several prizes. We limit how many tickets one account can hold so no one can completely dominate, and we’re transparent about this behavior.

---

### 8. One Shared “Template,” Many Raffles

**What we do:** Instead of building a whole new system for every raffle, we use one shared design and create a lightweight “instance” for each new raffle. A central “factory” keeps the list and the global settings (like the fee).

**Why:** Creating a full copy for every raffle would be expensive and slow. Lightweight instances are cheap and fast to create, so we can run many raffles without wasting resources. The factory also gives one place for things like the fee and who receives it.

**Trade-off:** We didn’t add “upgrading” the shared design in the first version; we wanted to keep the model simple and predictable.

---

### 9. Anyone Can “Close” the Raffle After the End Time

**What we do:** After the end time, any person or app can trigger the step that closes the raffle and decides success or failure. The seller doesn’t have to do it.

**Why:** So the seller can’t delay or refuse to close the raffle. If they don’t do it, someone else can. The result depends only on the rules and the data (e.g. how many tickets were sold), not on who triggers the closing step.

**Trade-off:** None from a fairness perspective—it only makes the system more neutral and reliable.

---

### 10. Limits on Tickets per Person and on Number of Winners

**What we do:** We cap how many tickets one account can buy (e.g. 10,000) and how many winners a single raffle can have (e.g. 200).

**Why:** The per-account cap keeps a single buyer from taking over the whole raffle. The winner cap keeps the “draw” process simple and safe and ensures we always have enough data to pick winners in a fair way.

**Trade-off:** Very large raffles (e.g. thousands of winners) would need a different design; we optimized for the common case and left room to extend later.

---

## Quick Summary

| What | Our choice | Main reason |
|------|------------|-------------|
| When does the raffle “succeed”? | Only when every ticket is sold | Simple, clear rule |
| How is the target defined? | Ticket price × number of tickets, no other option | No confusion or misconfiguration |
| What can people pay with? | Tokens only (e.g. stablecoins, wrapped currency) | Simpler and safer system |
| How do people get paid? | They claim; we don’t send automatically | Fewer failures, more control, better security |
| How are winners chosen? | Automatically at end time using past, fixed data | Fair and not manipulable |
| When are winners decided? | Right when we know it sold out | One clear moment, no dependency on who claims first |
| Can one person win multiple times? | Yes | Matches “more tickets = more chances” |
| How are new raffles created? | From a shared template, via a factory | Cheap and fast, one place for settings |
| Who can close the raffle? | Anyone after the end time | Seller can’t block or delay |
| Any limits? | Max tickets per person, max winners per raffle | Fairness and reliable winner selection |

---

## In One Paragraph

Sellers create a raffle and lock the prize. Buyers buy tickets during the open period. When the end time has passed, anyone can close the raffle. If every ticket was sold, the raffle succeeds: the system takes a small fee, pays the seller, picks winners automatically, and records what each winner gets. If not, the raffle fails: no fee, no winners, and everyone can get their money back and the seller can take the prize back. After that, winners and refund recipients claim their share when they want—we don’t send automatically. Every choice we made was to keep the rules simple, the outcome clear, and the system fair and secure.
