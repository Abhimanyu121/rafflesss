# Glossary

The words this project uses, and exactly what each one means. If code and this file disagree,
one of them is wrong and it is worth finding out which.

## People

**Seller** — the person who puts up the prize and receives the proceeds if the raffle sells out.
They are not an administrator: once a raffle is created they cannot change its terms, and they
cannot take the prize back except in the cases this glossary names.

**Buyer** — anyone who pays for tickets. A buyer may assign the tickets they pay for to a different
address, so the payer and the ticket holder are not always the same person.

**Ticket holder** — the address a ticket belongs to, which is what the draw reads. Distinct from
the payer.

**Winner** — a ticket holder whose ticket was drawn. Being a winner is a fact about a ticket, not
about a person, so one person holding several tickets may be a winner several times.

**Protocol** — the operator of the factory. Takes a percentage of the proceeds of a raffle that
sold out. Has no say in who wins and no access to escrowed funds.

## Things

**Raffle** — one sale of a fixed number of tickets for one prize, with a start time and a deadline.
Each raffle is independent and cannot be altered after creation.

**Factory** — the contract that creates raffles and holds the settings new raffles are born with.

**Prize** — the tokens the seller locks up, to be divided among the winners. Also called the asset.

**Payment token** — the token tickets are bought with. It may be the same token as the prize;
the two are tracked as separate obligations regardless.

**Ticket** — one entry in the draw. Tickets are numbered, and the numbers are what the draw picks
from. A ticket wins at most once.

**Target** — the amount that must be raised for the raffle to count as sold out. It always equals
the ticket price multiplied by the number of tickets, so "target reached" and "every ticket sold"
mean the same thing.

**Seed** — the single unpredictable number every winner is derived from. Supplied by the randomness
provider, never taken from anything already visible on chain.

**Randomness provider** — the outside source the seed comes from. Which provider a raffle uses is
fixed when the raffle is created and cannot be changed afterwards.

## States

A raffle is always in exactly one of these. Every action names the state it requires, and no action
infers the state from the current time.

**Active** — before the deadline. Tickets can be bought. Nothing can be paid out and nothing can be
taken back. The one exception: a seller may cancel a raffle that has sold no tickets at all, which
sends it straight to Failed.

**Randomness Pending** — the deadline passed, every ticket was sold, and the raffle is waiting for
its seed. No winner exists yet. Nothing can be claimed.

**Succeeded** — the seed arrived and winners were drawn. Winners claim prizes, the seller claims
proceeds, the protocol claims its fee. This state is permanent.

**Failed** — the raffle ended without selling out, or was cancelled while empty, or waited too long
for a seed, or was left unsettled long past its deadline. Buyers reclaim what they paid and the
seller reclaims the prize. No fee is taken. This state is permanent.

## Actions

**Finalize** — settling whether a raffle sold out, once the deadline has passed. Anyone may do it.
It decides the outcome of the sale and nothing else. It does not choose winners.

**Draw** — turning the seed into the list of winners and their shares. A separate step from
finalizing, deliberately, so that the person who triggers settlement cannot influence who wins.

**Claim** — taking money the contract already owes you. The contract never sends tokens on its own
initiative; every payment is pulled by the person owed, including the protocol's fee.

**Cancel** — a seller ending their own raffle before anyone has bought a ticket.

**Time out** — anyone ending a raffle that has waited too long for a seed, so that everyone can be
repaid. Exists so no outside failure can trap money.
