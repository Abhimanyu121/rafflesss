# How the Raffle Works, in Plain Language

*No code. If you want the technical version, read
[`PRODUCT_FLOW_AND_DECISIONS.md`](PRODUCT_FLOW_AND_DECISIONS.md).*

> **This document was rewritten after a security review.** The earlier version told readers the
> system was fair and that nobody could take the prize. Neither was true of the code as written.
> Four serious flaws were found and fixed. This version says what the system actually does.

---

## The idea

Someone has something they want to raffle off. They lock it in a contract. People buy tickets.
If every ticket sells, winners are drawn and the prize is split between them. If not, everybody
gets their money back and the prize goes home.

Nobody runs it. There is no operator who picks winners, holds the money, or decides anything.

---

## The three people involved

**The seller** puts up the prize and gets the money if every ticket sells.

**The buyers** pay for tickets. They either win a share of the prize or get refunded.

**The protocol** takes a small percentage of successful raffles, capped at ten percent, and has
no say in anything else.

---

## What happens, step by step

**1. The seller creates the raffle.** They choose the prize, the ticket price, how many tickets,
how long it runs, and how many winners. The prize moves into the contract straight away.

From that moment the prize is locked. The seller cannot take it back while tickets are on sale.
The one exception is that they can call the whole thing off while nobody has bought anything yet,
which is there for the case where they got the details wrong.

**2. People buy tickets.** You pay, you get tickets. You can buy them for someone else as a gift.
Once you have paid, your money stays in the contract until the raffle ends. There is no way to
change your mind.

**3. The raffle ends.** After the deadline, anybody can trigger the next step. Not just the
seller. This matters, because it means the seller cannot stall a raffle they dislike the look of.

Only one question gets answered here: did every ticket sell?

- **No.** The raffle failed. Everyone gets their money back and the seller takes the prize home.
- **Yes.** The contract asks for a random number and waits.

**4. The winners are drawn.** When the random number arrives, anybody can trigger the draw. The
winners are picked and the prize is divided between them.

**5. Everyone collects.** Winners collect their prize. In a failed raffle, buyers collect their
refunds and the seller collects the prize back. Nothing is ever sent automatically. You ask for
your money when you want it.

---

## Where does the random number come from?

From Chainlink, an outside service that produces random numbers and proves mathematically that it
did not fiddle with them. The contract checks that proof and refuses anything that fails it.

**The old version did this badly, and it is worth explaining why.**

It used to pick winners from the fingerprints of recent blocks on the blockchain. Those
fingerprints look random, and they cannot be altered once written. So it seemed safe.

The problem was not that anyone could change them. It was that anyone could *read them first*.
Because anybody was allowed to trigger the draw at any moment, and the fingerprints it would use
were already public, a ticket holder could work out who would win before doing anything. If it
was not them, they waited two seconds and checked again. Free retries, forever, until they won.

Imagine a lottery where the winning number is the temperature outside at the moment you press the
button. Nobody can change the weather. But you can look at the thermometer, and only press when
it suits you. The number is honest. The choosing is not.

In testing, somebody holding a third of the tickets waited about a minute and then won every
prize. Somebody who played honestly and triggered the draw straight away won nothing.

Now the random number does not exist yet at the moment the raffle is settled, so there is nothing
to look at and nothing to wait for.

---

## What happens if something goes wrong?

The main risk with relying on an outside service is that it goes quiet and your money is stuck.
So there are three ways out, and all of them refund everybody:

- The seller calls it off before anyone has bought a ticket.
- The random number does not arrive within a day.
- Nobody bothers to settle the raffle at all, and a month goes by.

Anyone can trigger the last two. Nothing depends on a particular person doing their job.

---

## What the contract will not let anyone do

- **The seller cannot take the prize back** once someone has bought a ticket, until the raffle has
  properly ended.
- **Buyers cannot pull their money out** partway through and still keep their tickets in the draw.
  The old version let them, which meant somebody could get a full refund and still win.
- **Nobody can create a raffle using your tokens.** The old version let a stranger name you as the
  seller and raffle your tokens off on terms they invented. If you have ever approved the old
  contract, cancel that approval.
- **The operator cannot change the rules of a raffle that is already running.** The fee is fixed
  when the raffle is created. The old version read it at the end, so the operator could set it to
  a hundred percent after all the tickets had sold and take everything.
- **The same ticket cannot win twice.** If you hold several tickets you can still win several
  prizes, which is the point of buying several. But one ticket cannot be paid out twice while
  another ticket that never won gets nothing, which is what used to happen.

---

## Things we are honest about

**Buying lots of tickets improves your odds.** That is how a raffle works. There is no limit on
how many one person can buy. There used to be a limit, but it was easy to sidestep with a second
wallet, and a rule that does not work is worse than no rule because people trust it.

**Once the random number arrives, anyone can work out the winners** before the draw is formally
recorded. This does not matter. The number is already fixed by then, so knowing the answer early
changes nothing.

**Some kinds of token do not work here.** Tokens that take a cut of every transfer are rejected
outright. Tokens that change your balance on their own are not safe to use and should be avoided.

**This code has not been independently audited.** It has been reviewed, the problems found are
written down publicly, and there are tests that reproduce every one of them. That is not the same
as an audit.

---

## The short version

Create, buy, settle, draw, collect. Nobody runs it. The prize is locked until the raffle properly
ends. Every ticket has to sell or everyone gets refunded. Winners are drawn using a random number
nobody can predict or choose. And if anything gets stuck, there is always a way for anyone to end
it and give everybody their money back.
