#let description = [
  The clock strikes midnight, the Year of the Monkey has finally arrived.

  On this first day of the new year, the Monkey Clan received congratulatory messages from all over the world. As the Monkey Clan leader, Hou Sai Lei, was happily reading them, a message from the Flea Kingdom caught his attention:

  "Happy Year of the Monkey! How could I, the Flea King, be absent on such a joyous occasion? Do you remember? It was during the selection of the twelve zodiac animals that you used your veto power to reject the flea. What an unforgettable memory. So today, I've brought some small gifts, really small gifts, and I hope you'll accept them. -- The Flea King"

  The Monkey Clan leader was stunned. Just then, a monkey soldier rushed in: "Bad news, the Flea Kingdom's army is at our gates!"

  The Flea Kingdom possesses the world's jumpiest tanks, capable of leaping directly from the front lines to the enemy's rear. The situation is critical. The Monkey Clan leader immediately ordered: "Enter a state of war, activate all Gundams, and equip the Sai Lei missiles to engage the enemy!"

  The Monkey Clan has a total of $1024$ Gundams. Each Gundam has an ID, an integer from $0$ to $2^32 - 1$ (not necessarily consecutive).

  The Monkey Clan has a total of $1024$ hangars, numbered from $0$ to $1023$. Each Gundam is stored in a hangar (*a hangar may store multiple Gundams*).

  The frontline generals only know the IDs of the Gundams under their command, but not their locations. Only the Monkey Clan leader knows which hangar each Gundam is in, so he needs to send this location information to the frontline generals.

  However, the Monkey Clan's communication technology is underdeveloped. The Monkey Clan leader has found you -- please design a communication method to transmit the Gundams' locations.

  You need to write a program that implements encoding and decoding functionalities.

  == Encoding

  If the task is encoding, the first line of input will be the string `encode`.

  The next $1024$ lines will each contain two integers, $k$ and $v$, indicating that the Gundam with ID $k$ is stored in hangar number $v$. It is guaranteed that $0 <= k < 2^32$, $0 <= v < 1024$, and *all $k$ values are distinct*.

  You need to output a *binary string* (a string of 0s and 1s), which represents the message sent to the frontline generals.

  == Decoding

  If the task is decoding, the first line of input will be the string `decode`.

  The next line will contain the binary string produced by your encoding program.

  The next line will contain a positive integer $Q$, representing the number of Gundams under a general's command.

  The next $Q$ lines will each contain an integer $k$, representing a Gundam ID. It is guaranteed that these are valid Gundam IDs and *all queried IDs are distinct*.

  For each Gundam ID, you need to output its corresponding hangar number on a new line.
]

#let input = none

#let output = none

#let notes = [
  If any decoded hangar number is incorrect, you will receive 0 points.

  If your program runs correctly, let the length of the encoded binary string be $n$. You will receive points based on the following table:

  #align(
    center,
    table(
      columns: 4,
      align: center + horizon,
      [*Score*], [*Condition*], [*Score*], [*Condition*],
      [1], [$n <= 10^5$], [6], [$n <= 15000$],
      [2], [$n <= 43008$], [7], [$n <= 14000$],
      [3], [$n <= 40000$], [8], [$n <= 13000$],
      [4], [$n <= 30000$], [9], [$n <= 12750$],
      [5], [$n <= 20000$], [10], [$n <= 12500$],
    ),
  )

  If multiple conditions are met, you will receive the highest score among them.

  Since your program will be executed twice (once for encoding and once for decoding), the time limit applies to the maximum of the two execution times.
]
