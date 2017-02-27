open Bootstrap3
structure Theme = Ui.Make(Style)
structure ThisTerm = Spring2017
val calBounds = {FromDay = ThisTerm.regDay,
                 ToDay = ThisTerm.classesDone}
val mailFrom = "MIT 6.887 <frap@csail.mit.edu>"

table user : { Kerberos : string, MitId : string, UserName : string, Password : option string,
               IsInstructor : bool, IsTA : bool, IsStudent : bool, IsListener : bool, HasDropped : bool,
               Units : string, SubjectNum : string, SectionNum : string, LastName : string, FirstName : string, MiddleInitial : string }
  PRIMARY KEY Kerberos,
  CONSTRAINT UserName UNIQUE UserName

table possibleOfficeHoursTime : { Time : time }
  PRIMARY KEY Time

table lecture : { LectureNum : int, LectureTitle : string, When : time, Description : string }
  PRIMARY KEY LectureNum,
  CONSTRAINT When UNIQUE When

table pset : { PsetNum : int, Released : time, Due : time, GradesDue : time, Instructions : string }
  PRIMARY KEY PsetNum

table hint : { PsetNum : int, Title : string, Text : string, ReleaseAt : time }
  PRIMARY KEY (PsetNum, Title),
  CONSTRAINT PsetNum FOREIGN KEY PsetNum REFERENCES pset(PsetNum) ON UPDATE CASCADE

table officeHours : { OhUser : string, When : time }
  PRIMARY KEY When

(* Bootstrap the database with an initial admin user. *)
task initialize = fn () =>
  anyUsers <- oneRowE1 (SELECT COUNT( * ) > 0
                        FROM user);
  if anyUsers then
      return ()
  else
      dml (INSERT INTO user(Kerberos, MitId, UserName, Password, IsInstructor, IsTA, IsStudent, IsListener, HasDropped, Units, SubjectNum, SectionNum, LastName, FirstName, MiddleInitial)
           VALUES ('adamc', '', 'Adam Chlipala', NULL, TRUE, FALSE, FALSE, FALSE, FALSE, '', '', '', '', '', ''))

structure Auth = MitCert.Make(struct
                                  con kerberos = #Kerberos
                                  con commonName = #UserName
                                  con groups = [IsInstructor, IsTA, IsStudent, IsListener, HasDropped]
                                  val users = user
                                  val defaults = Some {IsInstructor = False,
                                                       IsTA = False,
                                                       IsStudent = False,
                                                       IsListener = False,
                                                       HasDropped = False,
                                                       MitId = "",
                                                       Units = "",
                                                       SubjectNum = "",
                                                       SectionNum = "",
                                                       LastName = "",
                                                       FirstName = "",
                                                       MiddleInitial = ""}
                                  val allowMasquerade = Some (make [#IsInstructor] ())
                                  val requireSsl = True
                              end)

val whoami' = s <- Auth.whoamiWithMasquerade;
    return (case s of
                None => None
              | Some s => Some {UserName = s})

val gInstructor = make [#IsInstructor] ()
val amInstructor = Auth.inGroup gInstructor
val requireInstructor = Auth.requireGroup gInstructor
val instructorOnly =
    b <- amInstructor;
    return (if b then
                Calendar.Write
            else
                Calendar.Read)

val gStudent = make [#IsStudent] ()
val gListener = make [#IsListener] ()
val gTA = make [#IsTA] ()
val gsStudent = (gInstructor, gTA, gStudent, gListener)
val whoamiStudent = Auth.getGroupsWithMasquerade gsStudent
val amStudent = Auth.inGroups (gStudent, gListener)

val gsStaff = (gInstructor, gTA)
val whoamiStaff = Auth.getGroups gsStaff
val amStaff = Auth.inGroups gsStaff
val requireStaff = Auth.requireGroups gsStaff
val getStaff = Auth.getGroupsWithMasquerade gsStaff

val showPset = mkShow (fn {PsetNum = n : int} => "Pset " ^ show n)

structure PsetSub = Submission.Make(struct
                                        val tab = pset
                                        con ukey = #UserName
                                        val user = user
                                        val whoami = Auth.whoamiWithMasquerade
                                        con fs = [Hours = (int, _, _),
                                                  Suggestions = (string, _, _)]
                                        val labels = {Hours = "Hours spent on the pset (round to nearest integer)",
                                                      Suggestions = "Suggestions for improving the pset"}

                                        fun makeFilename k u = "ps" ^ show k.PsetNum ^ "_" ^ u ^ ".v"
                                        fun mayInspect uo =
                                            staff <- amStaff;
                                            if staff then
                                                return True
                                            else
                                                u <- whoamiStudent;
                                                return (uo = Some u)
                                    end)

table psetGrade : { PsetNum : int, PsetStudent : string, Grader : string, When : time, Grade : int, Comment : string }
  PRIMARY KEY (PsetNum, PsetStudent, Grader, When),
  CONSTRAINT PsetNum FOREIGN KEY PsetNum REFERENCES pset(PsetNum) ON UPDATE CASCADE,
  CONSTRAINT Student FOREIGN KEY PsetStudent REFERENCES user(UserName) ON UPDATE CASCADE,
  CONSTRAINT Grader FOREIGN KEY Grader REFERENCES user(UserName) ON UPDATE CASCADE

val psetGradeShow : show {PsetNum : int, PsetStudent : string}
  = mkShow (fn r => "Pset " ^ show r.PsetNum ^ ", " ^ r.PsetStudent)

val oneDayInSeconds = 24 * 60 * 60
val penaltyPerDay = 20

fun latePenalty key r =
    let
        val sub = PsetSub.submission
    in
        due <- oneRowE1 (SELECT (pset.Due)
                         FROM pset
                         WHERE pset.PsetNum = {[key.PsetNum]});
        turnedIn <- oneRowE1 (SELECT (sub.When)
                              FROM sub
                              WHERE sub.UserName = {[key.PsetStudent]}
                                AND sub.PsetNum = {[key.PsetNum]}
                              ORDER BY sub.When DESC
                              LIMIT 1);
        let
            val lateBy = diffInSeconds due turnedIn
        in
            if lateBy <= 0 then
                (* On time! *)
                return r
            else
                let
                    val daysLate = lateBy / oneDayInSeconds
                    val daysLate = if lateBy % oneDayInSeconds = 0 then
                                       daysLate
                                   else
                                       daysLate + 1
                    val adjustedGrade = r.Grade - daysLate * penaltyPerDay
                in
                    return (r -- #Grade ++ {Grade = max adjustedGrade 0})
                end
        end
    end

structure PsetGrade = Review.Make(struct
                                      con reviewer = #Grader
                                      con reviewed = [PsetNum = _, PsetStudent = _]
                                      val tab = psetGrade
                                      val labels = {Grade = "Grade",
                                                    Comment = "Comment"}
                                      val widgets = {Comment = Widget.htmlbox} ++ _
                                      fun summarize r = txt r.Grade
                                      val whoami = u <- whoamiStaff; return (Some u)
                                      val adjust = latePenalty
                                  end)

val gradeTree = Grades.assignments
                [[PsetNum = _]]
                [#PsetStudent]
                [#When]
                [#Grade]
                [#UserName]
                "Overall"
                pset
                user
                psetGrade

structure GradeTree = struct
    val t = gradeTree
end

structure AllGrades = Grades.AllStudents(GradeTree)
structure StudentGrades = Grades.OneStudent(GradeTree)

structure Sm = LinearStateMachine.Make(struct
                                           con steps = [PlanningCalendar,
                                                        ReleaseCalendar,
                                                        PollingAboutOfficeHours,
                                                        SteadyState,
                                                        AssigningFinalGrades,
                                                        SemesterOver]
                                           val mayChange = amInstructor
                                       end)

val showLectureNum = mkShow (fn {LectureNum = n : int} => "Lecture " ^ show n)

structure LectureSub = Submission.Make(struct
                                           val tab = lecture
                                           con ukey = #UserName
                                           val user = user
                                           val whoami = u <- whoamiStaff; return (Some u)
                                           val labels = {}

                                           fun makeFilename k _ = "Lecture" ^ show k.LectureNum ^ ".v"
                                           fun mayInspect _ = return True
                                       end)

val showLabNum = mkShow (fn {LabNum = n : int} => "Lab " ^ show n)

structure PsetSpec = Submission.Make(struct
                                       val tab = pset
                                       con ukey = #UserName
                                       val user = user
                                       val whoami = u <- whoamiStaff; return (Some u)
                                       val labels = {}

                                       fun makeFilename k _ = "Pset" ^ show k.PsetNum ^ ".v"
                                       fun mayInspect _ = return True
                                   end)

val courseInfo =
    Ui.const <xml>
      <div class="jumbotron">
        <div class="container">
          <h1>Formal Reasoning About Programs</h1>

          <p>A graduate course at MIT in Spring 2017</p>
        </div>
      </div>

      <table class="bs3-table table-striped">
        <tr> <th>Subject number:</th> <td>6.887</td> </tr>
        <tr> <th>Instructor:</th> <td><a href="http://adam.chlipala.net/">Adam Chlipala</a></td> </tr>
        <tr> <th>Teaching assistant:</th> <td><a href="http://people.csail.mit.edu/joonwonc/">Joonwon Choi</a></td> </tr>
        <tr> <th>Class meets:</th> <td>MW 2:30-4:00, 34-304</td> </tr>
      </table>

      <h3>Key links: <a href="http://adam.chlipala.net/frap/">book and related source code</a>; <a href="https://github.com/mit-frap/spring17">GitHub repo with problem sets</a></h3>

      <h2>What's it all about?</h2>

      <p><i>Briefly</i>, this course is about an approach to bringing software engineering up to speed with more traditional engineering disciplines, providing a mathematical foundation for rigorous analysis of realistic computer systems.  As civil engineers apply their mathematical canon to reach high certainty that bridges will not fall down, the software engineer should apply a different canon to argue that programs behave properly.  As other engineering disciplines have their computer-aided-design tools, computer science has <i>proof assistants</i>, IDEs for logical arguments.  We will learn how to apply these tools to certify that programs behave as expected.</p>

      <p><i>More specifically</i>: Introductions to two intertangled subjects: <b><a href="http://coq.inria.fr/">the Coq proof assistant</a>, a tool for machine-checked mathematical theorem proving</b>; and <b>formal logical reasoning about the correctness of programs</b>.  The latter category overlaps significantly with MIT's <a href="http://stellar.mit.edu/S/course/6/fa15/6.820/">6.820</a>, but we will come to appreciate the material at a different level, by focusing on machine-checked proofs, both of the soundness of general reasoning techniques and of the correctness of particular programs.</p>

      <p>We welcome participation by graduate and undergraduate students from MIT and other local universities, as well as other auditors interested in jumping into this material.  Per MIT's academic calendar, the first class meeting will be on February 8th.</p>

      <h2>Major topics covered</h2>

      <p>Here's a tentative syllabus.</p>

      <table class="bs3-table table-striped">
        <tr><th>Foundations</th></tr>
        <tr><td>Inductive types, recursive functions, induction, and rewriting: the heart of formal reasoning, and useful for defining and reasoning about language interpreters</td></tr>
        <tr><td>Data abstraction in the presence of formal proofs</td></tr>
        <tr><td>Inductively defined relations and rule induction, applied to invariant-based verification of state machines</td></tr>
        <tr><td>Model checking and abstraction: finitizing state spaces with clever relations</td></tr>
        <tr><td>Operational semantics: the standard approach to give meanings to programs</td></tr>
        <tr><td>Compiler verification</td></tr>

        <tr><th>Type Systems</th></tr>
        <tr><td>Lambda-calculus semantics</td></tr>
        <tr><td>Type systems and the syntactic approach to type soundness</td></tr>
        <tr><td>Advanced type-system features: subtyping, mutable references</td></tr>

        <tr><th>Program Logics</th></tr>
        <tr><td>Hoare logic: an approach to verifying imperative programs</td></tr>
        <tr><td>Deep embeddings, shallow embeddings, and options in between: choices for how to represent programs formally</td></tr>
        <tr><td>Separation logic: reasoning about aliasing and pointer-based data structures</td></tr>

        <tr><th>Concurrency</th></tr>
        <tr><td>Operational semantics for concurrent programs, illustrated with partial-order reduction for model checking</td></tr>
        <tr><td>Concurrent Separation Logic and rely-guarantee reasoning: verifying shared-memory programs</td></tr>
        <tr><td>Pi-calculus and behavioral refinement: modular reasoning about message-passing functional programs</td></tr>
      </table>

      <h2>The big ideas</h2>

      <p>That's quite a lot of topics, isn't it?  We'll be sticking to techniques for proving <i>safety properties</i> (and we'll clarify what that term means), so there's even a whole other world of foundational ideas for proving other sorts of program properties!  Nonetheless, a key goal of the course is to clarify how all of these techniques can be seen as applying a few <b>big ideas</b> of semantics and verification:</p>

      <table class="bs3-table table-striped">
        <tr><th>Encoding</th> <td>There are an awful lot of different ways to formalize the shape and behavior of programs, and the choice of a method can have big consequences for how easy the proofs are.</td></tr>
        <tr><th>Invariants</th> <td>Almost all program proofs come down to finding invariants of state machines.  That is, we prove that some property holds of all reachable states of a formal system, and we show that the property implies the one we started out trying to prove.</td></tr>
        <tr><th>Abstraction</th> <td>Often we replace one state machine with a simpler one that somehow represents it faithfully enough with respect to the property of interest.</td></tr>
        <tr><th>Modularity</th> <td>We also often break a complex state machine into several simpler ones that can be analyzed independently.</td></tr>
      </table>

      <h2>Mechanics</h2>

      <p>Most homework assignments are mechanized proofs that are checked automatically.  Once a month, though, we'll have an assignment that also involves choosing the right theorems to prove in the first place, which usually involves defining some program reasoning system for a domain that we describe in a handout.</p>

      <p>There are two lectures per week.  At the very beginning, we'll spend all the lecture time on basics of Coq.  Shortly afterward, we'll switch to, each week, having one lecture on a concept in semantics and/or proofs of program correctness and one lecture on some moderate-to-advanced feature of Coq.  In roughly the last month of class, the Coq-feature lectures will be replaced by presentations on full-scale research projects at MIT that use Coq to establish correctness of fairly realistic software or hardware systems.  (The details are open to influence by the interests of the students, but the instructor's current guess is lectures on <a href="http://css.csail.mit.edu/fscq/">FSCQ</a>, <a href="http://plv.csail.mit.edu/fiat/">Fiat</a>, <a href="https://github.com/mit-plv/fiat-crypto">Fiat Cryptography</a>, and <a href="http://plv.csail.mit.edu/kami/">Kami</a>.)</p>

      <p>Grades are based entirely on <i>problem sets</i> (mostly graded by the machines), and a new one is released right after each Wednesday lecture, due a week later (or a little earlier, usually starts of class periods; see each assignment's posting for details).  Late problem-set turn-in is accepted, but 20% is subtracted from the grade for every day late, starting one second after the posted deadline, so don't bet your grade on details of the server's clock!  (In other words, any fractional late time is rounded up to a whole day, before applying the 20%-per-day penalty.)</p>

      <p>It takes a while to internalize all the pro trips for writing Coq proofs productively.  It really helps to have experts nearby to ask in person.  For that reason, we will also have copious <i>office hours</i>, in the neighborhood of 10 hours per week.  Course staff members will be around, and we also encourage students to help each other at these sessions.  We'll take a poll on the best times for office hours, but the default theory is that the day before an assignment is due and the day after it is released are the best times.</p>

      <p><b>Academic integrity guidelines:</b> Learning to drive a proof assistant is hard work, and it's valuable to be able to ask for help from your classmates.  For that reason, we allow asking for help from classmates, not just the course staff, with no particular acknowledgment in turned-in solutions.  However, the requirement is that <i>you have entered your problem-set code/proofs yourself, without someone else looking over your shoulder telling you more or less what to type at every stage</i>.  Use your judgment about exactly which interaction styles will stay compatible with this rule.  You'll generally learn more as you spend time working through the parts of assignments where you don't wind up stuck on something, and it's generally valuable to seek help (from classmates or course staff) when you're stuck.</p>

      <h2>Prerequisites</h2>

      <p>Two main categories of prior knowledge are assumed: <i>mathematical foundations of computer science, including rigorous proofs with induction</i>; and <i>intermediate-level programming experience, including familiarity with concepts like higher-order functions, pointers, and multithreading</i>.  MIT's 6.042 and 6.005/6.004 should respectively satisfy those requirements, but many other ways of coming by this core knowledge should also be fine.  We'll start off pretty quickly with functional programming in Coq, as our main vehicle for expressing programs and their specifications.  Many students find it unnecessary to have studied functional programming beforehand, but others appreciate learning a bit about Haskell or OCaml on their own first.  (6.820 also provides lightning-speed introductions to those languages.)</p>

      <h2>Suggested reading</h2>

      <p>The main source is <a href="http://adam.chlipala.net/frap/">the book <i>Formal Reasoning About Programs</i></a>, which is in decent shape from last year's offering of this subject, but which will have some moderate changes made as we go.</p>

      <p>The course is intended to be self-contained, and notes and example Coq code will be in <a href="https://github.com/achlipala/frap">the book's GitHub repo</a>.  We'll also be using a custom Coq library designed to present a relatively small set of primitive commands to be learned.  However, the following popular sources may be helpful supplements.</p>

      <h3>The Coq proof assistant</h3>

      <ul>
        <li><a href="http://adam.chlipala.net/cpdt/"><i>Certified Programming with Dependent Types</i></a>, the instructor's book introducing Coq at a more advanced level</li>
        <li><a href="https://www.labri.fr/perso/casteran/CoqArt/"><i>Interactive Theorem Proving and Program Development (Coq'Art)</i></a>, the first book about Coq</li>
        <li><a href="http://www.cis.upenn.edu/~bcpierce/sf/"><i>Software Foundations</i></a>, a popular introduction to Coq that covers ideas similar to the ones in this course, at a slower pace</li>
      </ul>

      <h3>Semantics and program proof</h3>

      <ul>
        <li><a href="https://www.cis.upenn.edu/~bcpierce/tapl/"><i>Types and Programming Languages</i></a></li>
        <li><a href="https://mitpress.mit.edu/books/formal-semantics-programming-languages"><i>The Formal Semantics of Programming Languages: An Introduction</i></a></li>
        <li><a href="http://www.amazon.com/Practical-Foundations-Programming-Languages-Professor/dp/1107029570"><i>Practical Foundations for Programming Languages</i></a></li>
      </ul>

      <h2>This web app...</h2>

      <p>...is built using advanced type-system ideas relevant to the course, and <a href="https://github.com/achlipala/frapapp">the source code is available</a>.  Pull requests welcome!</p>
    </xml>

val usernameShow = mkShow (fn {UserName = s} => s)
val timeShow = mkShow (fn {Time = t : time} => show t)

structure Smu = Sm.MakeUi(struct
                              val steps = {PlanningCalendar = {Label = "Planning calendar",
                                                               WhenEntered = fn _ => return ()},
                                           ReleaseCalendar = {Label = "Release calendar",
                                                              WhenEntered = fn _ => return ()},
                                           PollingAboutOfficeHours = {Label = "Polling about office hours",
                                                                      WhenEntered = fn _ => return ()},
                                           SteadyState = {Label = "Steady state",
                                                          WhenEntered = fn _ => return ()},
                                           AssigningFinalGrades = {Label = "Assigning final grades",
                                                                   WhenEntered = fn _ => return ()},
                                           SemesterOver = {Label = "Semester over",
                                                           WhenEntered = fn _ => return ()}}
                          end)

fun getLecture num =
    oneRow1 (SELECT lecture.LectureTitle, lecture.Description, lecture.When
             FROM lecture
             WHERE lecture.LectureNum = {[num]})

val showLecture = mkShow (fn {LectureNum = n : int, LectureTitle = s} => "Lecture " ^ show n ^ ": " ^ s)

structure LectureCal = Calendar.FromTable(struct
                                              con tag = #Lecture
                                              con key = [LectureNum = _, LectureTitle = _]
                                              con times = [When]
                                              val tab = lecture
                                              val title = "Lecture"
                                              val labels = {LectureNum = "Lecture#",
                                                            LectureTitle = "Title",
                                                            Description = "Description",
                                                            When = "When"}
                                              val kinds = {When = ""}
                                              val ws = {Description = Widget.htmlbox} ++ _
                                              val display = Some (fn ctx r =>
                                                                     content <- source <xml/>;
                                                                     lec <- rpc (getLecture r.LectureNum);
                                                                     set content (Ui.simpleModal
                                                                                      <xml>
                                                                                        <h2>Lecture #{[r.LectureNum]}: {[lec.LectureTitle]}</h2>
                                                                                        <h3>{[lec.When]}</h3>
                                                                      
                                                                                        {Widget.html lec.Description}

                                                                                        
                                                                                      </xml>
                                                                                      <xml>Close</xml>);
                                                                     return <xml>
                                                                       <dyn signal={signal content}/>
                                                                     </xml>)

                                              val auth = instructorOnly
                                              val showTime = True
                                          end)

fun getPset num =
    oneRow1 (SELECT pset.Instructions, pset.Released, pset.Due
             FROM pset
             WHERE pset.PsetNum = {[num]})

structure PsetCal = Calendar.FromTable(struct
                                           con tag = #Pset
                                           con key = [PsetNum = _]
                                           con times = [Released, Due]
                                           val tab = pset
                                           val title = "Pset"
                                           val labels = {PsetNum = "Pset#",
                                                         Instructions = "Instructions",
                                                         Released = "Released",
                                                         Due = "Due",
                                                         GradesDue = "Grades due"}
                                           val kinds = {Released = "released", Due = "due"}
                                           val ws = {Instructions = Widget.htmlbox} ++ _
                                           val display = Some (fn ctx r =>
                                                                  content <- source <xml/>;
                                                                  lb <- rpc (getPset r.PsetNum);
                                                                  set content (Ui.simpleModal
                                                                                   <xml>
                                                                                     <h2>Pset #{[r.PsetNum]}</h2>
                                                                                     <h3>Released {[lb.Released]}<br/>
                                                                                     Due {[lb.Due]}</h3>
                                                                                     
                                                                                     <button class="btn btn-primary"
                                                                                              onclick={fn _ =>
                                                                                                          xm <- PsetSub.newUpload r;
                                                                                                          set content xm}>
                                                                                       New Submission
                                                                                     </button>

                                                                                     <hr/>

                                                                                     {Widget.html lb.Instructions}
                                                                                   </xml>
                                                                                   <xml>Close</xml>);
                                                                  return <xml>
                                                                    <dyn signal={signal content}/>
                                                                  </xml>)

                                           val auth = instructorOnly
                                           val showTime = True
                                       end)

val showOh = mkShow (fn {OhUser = s} => s ^ "'s office hours")

structure OhCal = Calendar.FromTable(struct
                                          con tag = #OfficeHours
                                          con key = [OhUser = _]
                                          con times = [When]
                                          val tab = officeHours
                                          val title = "Office Hours"
                                          val labels = {OhUser = "Who",
                                                        When = "When"}
                                          val kinds = {When = ""}
                                          val display = None

                                          val auth = instructorOnly
                                          val showTime = True

                                          val ws = {OhUser = Widget.foreignbox_default
                                                                 (SELECT (user.UserName)
                                                                  FROM user
                                                                  WHERE user.IsInstructor OR user.IsTA)
                                                                 ""} ++ _
                                      end)

structure PublicCal = Calendar.Make(struct
                                        val t = ThisTerm.cal
                                                    |> Calendar.compose OhCal.cal
                                                    |> Calendar.compose PsetCal.cal
                                                    |> Calendar.compose LectureCal.cal
                                    end)

val calUi = Ui.seq (Ui.h4 <xml>
  Lecture is in 34-304.<br/>
  Joonwon's Monday and Wednesday office hours are in 34-301 (usually 4 PM to 7 PM), while Joonwon's Thursday office hours are in 34-302 (usually 3 PM to 6 PM).
</xml>, PublicCal.ui calBounds)

val forumAccess = staff <- amStaff;
    if staff then
        u <- Auth.getUserWithMasquerade;
        return (Discussion.Admin {User = u})
    else
        student <- amStudent;
        if student then
            u <- Auth.getUserWithMasquerade;
            return (Discussion.Post {User = u, MayEdit = True, MayDelete = True, MayMarkClosed = True})
        else
            return Discussion.Read

fun emailOf kerb =
    case String.index kerb #"@" of
        Some _ => kerb
      | None => kerb ^ "@mit.edu"

fun toOf {UserName = name, Kerberos = kerb} =
    name ^ " <" ^ emailOf kerb ^ ">"

fun onNewMessage kind getUsers r =
    us <- getUsers;
    us <- query (SELECT user.UserName
                 FROM user
                 WHERE user.IsInstructor OR user.IsTA)
          (fn {User = {UserName = u}} us =>
              return (if List.mem u us then
                          us
                      else
                          u :: us)) us;

    u <- Auth.whoami;
    let
        val us = case u of
                     None => error <xml>Posting message while not logged in</xml>
                   | Some u => List.filter (fn u' => u' <> u) us

        val hs = Mail.empty
                     |> Mail.from mailFrom
                     |> Mail.to mailFrom
                     |> Mail.subject "New forum message"
    in
        hs <- query (SELECT user.UserName, user.Kerberos
                     FROM user
                     WHERE {List.foldl (fn name p =>
                         (WHERE user.UserName = {[name]} OR {p})) (WHERE FALSE) us})
              (fn {User = {UserName = name, Kerberos = kerb}} hs =>
                  return (Mail.bcc (toOf {UserName = name, Kerberos = kerb}) hs)) hs;
        let
            val textm = "Let it be known that there is a new MIT 6.887 "
                        ^ kind
                        ^ " forum message posted by "
                        ^ r.Who
                        ^ " in the thread \""
                        ^ r.Subject
                        ^ ".\"\n"

            val htmlm = <xml>
              Let it be known that there is a new <a href="https://frap.csail.mit.edu/Private/student">MIT 6.887</a> {[kind]} forum message posted by <i>{[r.Who]}</i> in the thread <i>{[r.Subject]}</i>.
            </xml>
        in
            Mail.send hs textm (Some htmlm)
        end
    end

structure GlobalForum = GlobalDiscussion.Make(struct
                                                  val text = Widget.htmlbox
                                                  val access = forumAccess
                                                  val showOpenVsClosed = True
                                                  val allowPrivate = True
                                                  val onNewMessage = onNewMessage "global"
                                              end)

structure LectureForum = TableDiscussion.Make(struct
                                                  con key1 = #LectureNum
                                                  con keyR = []
                                                  con thread = #Thread
                                                  val parent = lecture

                                                  val text = Widget.htmlbox
                                                  fun access _ = forumAccess
                                                  val showOpenVsClosed = True
                                                  val allowPrivate = True
                                                  val onNewMessage = onNewMessage "lecture"
                                              end)

structure PsetForum = TableDiscussion.Make(struct
                                               con key1 = #PsetNum
                                               con keyR = []
                                               con thread = #Thread
                                               val parent = pset

                                               val text = Widget.htmlbox
                                               fun access _ = forumAccess
                                               val showOpenVsClosed = True
                                               val allowPrivate = True
                                               val onNewMessage = onNewMessage "pset"
                                           end)

structure LectureTodo = Todo.Happenings(struct
                                            con tag = #Lecture
                                            con key = [LectureNum = _, LectureTitle = _]
                                            con when = #When
                                            val items = lecture
                                            con ukey = #UserName
                                            val users = user
                                            val ucond = (WHERE Users.IsStudent OR Users.IsInstructor OR Users.IsTA)
                                            val title = "Lecture"
                                            fun render r = <xml>{[r]}</xml>
                                        end)

structure Ann = News.Make(struct
                              val title = Widget.textbox
                              val body = Widget.htmlbox

                              val access = staff <- amStaff;
                                  if staff then
                                      u <- Auth.getUserWithMasquerade;
                                      return (News.Admin {User = u})
                                  else
                                      return News.Read

                              fun onNewPost r =
                                  let
                                      val hs = Mail.empty
                                                   |> Mail.from mailFrom
                                                   |> Mail.to mailFrom
                                                   |> Mail.subject ("Announcement: " ^ r.Title)
                                  in
                                      hs <- query (SELECT user.UserName, user.Kerberos
                                                   FROM user
                                                   WHERE user.IsInstructor
                                                     OR user.IsTA
                                                     OR user.IsStudent
                                                     OR user.IsListener)
                                                  (fn {User = r} hs =>
                                                      return (Mail.bcc (toOf r) hs)) hs;
                                      let
                                          val textm = Html.unhtml r.Body

                                          val htmlm = <xml>
                                            {Widget.html r.Body}

                                            <p><a href="https://frap.csail.mit.edu/Private/student">MIT 6.887 site</a></p>
                                          </xml>
                                      in
                                          Mail.send hs textm (Some htmlm)
                                      end
                                  end
                          end)

structure Private = struct

    val adminPerm =
        b <- amInstructor;
        return {Add = b, Delete = b, Modify = b}

    structure EditUser = EditableTable.Make(struct
                                                val tab = user
                                                val labels = {Kerberos = "Kerberos",
                                                              UserName = "Name",
                                                              Password = "Password",
                                                              IsInstructor = "Instructor?",
                                                              IsTA = "TA?",
                                                              IsStudent = "Student?",
                                                              IsListener = "Listener?",
                                                              HasDropped = "Dropped?",
                                                              MitId = "MIT ID",
                                                              Units = "Units",
                                                              SubjectNum = "Subject",
                                                              SectionNum = "Section",
                                                              LastName = "Last",
                                                              FirstName = "First",
                                                              MiddleInitial = "MI"}

                                                val permission = adminPerm
                                                fun onAdd _ = return ()
                                                fun onDelete _ = return ()
                                                fun onModify _ = return ()
                                            end)

    structure EditHint = EditableTable.Make(struct
                                                val tab = hint
                                                val labels = {PsetNum = "Pset#",
                                                              ReleaseAt = "Release at",
                                                              Title = "Title",
                                                              Text = "Text"}

                                                val widgets = {PsetNum = Widget.foreignbox_default (SELECT (pset.PsetNum) FROM pset ORDER BY pset.PsetNum) 0,
                                                               ReleaseAt = _,
                                                               Title = _,
                                                               Text = Widget.htmlbox}

                                                val permission = adminPerm
                                                fun onAdd _ = return ()
                                                fun onDelete _ = return ()
                                                fun onModify _ = return ()
                                            end)

    structure EditPossOh = EditableTable.Make(struct
                                                  val tab = possibleOfficeHoursTime
                                                  val labels = {Time = "Time"}

                                                  val permission = adminPerm
                                                  fun onAdd _ = return ()
                                                  fun onDelete _ = return ()
                                                  fun onModify _ = return ()
                                              end)

    structure OhPoll = ClosedBallot.Make(struct
                                             con voterKey1 = #UserName
                                             con voterKeyR = []
                                             val voter = user

                                             con choiceBallot = []
                                             con choiceKey1 = #Time
                                             con choiceKeyR = []
                                             val choice = possibleOfficeHoursTime

                                             val amVoter = whoami'
                                             val maxVotesPerVoter = Some 1
                                             val keyFilter = (WHERE TRUE)
                                         end)

    structure PsetTodoStudent = Todo.WithDueDate(struct
                                                     con tag = #Pset
                                                     con due = #Due
                                                     con key = [PsetNum = int]
                                                     val items = pset
                                                     val done = PsetSub.submission
                                                     con ukey = #UserName
                                                     val users = user
                                                     val title = "Pset"
                                                     val ucond = (WHERE Users.IsStudent)
                                                     val allowAnyUser = False

                                                     fun render r _ = <xml>{[r]}</xml>
                                                 end)

    structure StudentTodo = Todo.Make(struct
                                          val t = LectureTodo.todo
                                                      |> Todo.compose PsetTodoStudent.todo
                                      end)

    fun oldPset id =
        u <- whoamiStudent;
        ps <- oneRow1 (SELECT pset.Released, pset.Due, pset.Instructions
                       FROM pset
                       WHERE pset.PsetNum = {[id]});
        Theme.simple ("MIT 6.887: Pset " ^ show id) (Ui.seq
          (Ui.constM (fn ctx => <xml>
            <h2>Pset {[id]}</h2>
            <h3>Released: {[ps.Released]}<br/>
              Due: {[ps.Due]}</h3>
              {Widget.html ps.Instructions}<br/>

              {Ui.modalButton ctx (CLASS "btn btn-primary") <xml>New Submission</xml>
                              (PsetSub.newUpload {PsetNum = id})}
              
              <hr/>

              <h3>Solution</h3>
          </xml>),
          PsetSpec.AllFilesAllUsers.ui {PsetNum = id},
          Ui.const <xml>
            <hr/>
            <h2>Your Submissions</h2>
          </xml>,
          PsetSub.AllFiles.ui {Key = {PsetNum = id}, User = u},
          Ui.const <xml>
            <hr/>
            <h2>Forum</h2>
          </xml>,
          PsetForum.ui {PsetNum = id}))

    fun student masqAs =
        (case masqAs of
             "" => Auth.unmasquerade
           | _ => Auth.masqueradeAs masqAs);

        u <- whoamiStudent;
        key <- return {UserName = u};
        st <- Sm.current;

        lec <- oneOrNoRows1 (SELECT lecture.LectureNum, lecture.LectureTitle, lecture.When, lecture.Description
                             FROM lecture
                             WHERE lecture.When < CURRENT_TIMESTAMP
                             ORDER BY lecture.When DESC
                             LIMIT 1);

        lecr <- return (Option.get {LectureNum = 0,
                                    LectureTitle = "",
                                    When = minTime,
                                    Description = ""} lec);

        ps <- oneOrNoRows1 (SELECT pset.PsetNum, pset.Released, pset.Due, pset.Instructions
                            FROM pset
                            WHERE pset.Released < CURRENT_TIMESTAMP AND CURRENT_TIMESTAMP < pset.Due
                            ORDER BY pset.Due DESC
                            LIMIT 1);

        psr <- return (Option.get {PsetNum = 0,
                                   Released = minTime,
                                   Due = minTime,
                                   Instructions = ""} ps);

        oldPsets <- queryX1 (SELECT pset.PsetNum
                             FROM pset
                             WHERE pset.Due < CURRENT_TIMESTAMP
                             ORDER BY pset.Due)
                            (fn r => <xml><tr><td><a link={oldPset r.PsetNum}>{[r]}</a></td></tr></xml>);

        hints <- queryX1 (SELECT hint.PsetNum, hint.Title, hint.Text
                          FROM hint
                          WHERE hint.ReleaseAt < CURRENT_TIMESTAMP
                          ORDER BY hint.ReleaseAt DESC)
                 (fn r => <xml><tr>
                   <td>{[r.PsetNum]}</td>
                   <td>{[r.Title]}</td>
                   <td>{Widget.html r.Text}</td>
                 </tr></xml>);

        Theme.tabbed "MIT 6.887, Spring 2017, student page"
        ((Ui.when (st = make [#PollingAboutOfficeHours] ()) "Poll on Favorite Office-Hours Times",
          Ui.seq (Ui.h4 <xml>These times are listed for particular days in a particular week, but please interpret the poll as a question about your general weekly schedule.</xml>,
                 OhPoll.ui {Ballot = (), Voter = key})),
         (Ui.when (st >= make [#ReleaseCalendar] ()) "Todo",
          StudentTodo.OneUser.ui u),
         (Ui.when (st >= make [#ReleaseCalendar] ()) "Calendar",
          calUi),
         (Some "News",
          Ann.ui),

         (case ps of
              None => None
            | Some _ => Some "Current Pset",
          Ui.seq (Ui.constM (fn ctx => <xml>
            <h2>Pset {[psr.PsetNum]}</h2>
            <h3>Released: {[psr.Released]}<br/>
            Due: {[psr.Due]}</h3>
            {Widget.html psr.Instructions}<br/>

            {Ui.modalButton ctx (CLASS "btn btn-primary") <xml>New Submission</xml>
                            (PsetSub.newUpload {PsetNum = psr.PsetNum})}
           
            <hr/>

            <h3>Solution</h3>
          </xml>),
          PsetSpec.AllFilesAllUsers.ui {PsetNum = psr.PsetNum},
          Ui.const <xml>
            <hr/>
            <h2>Your Submissions</h2>
          </xml>,
          PsetSub.AllFiles.ui {Key = {PsetNum = psr.PsetNum}, User = u},
          Ui.const <xml>
            <hr/>
            <h2>Forum</h2>
          </xml>,
          PsetForum.ui {PsetNum = psr.PsetNum})),
         (Some "Pset Hints",
          Ui.const <xml>
            <table class="bs3-table table-striped">
              <tr> <th>Pset#</th> <th>Title</th> <th>Hint</th> </tr>
              {hints}
            </table>
          </xml>),

         (case lec of
              None => None
            | Some _ => Some "Last Lecture",
          Ui.seq (Ui.const <xml>
            <h2>Lecture {[lecr.LectureNum]}: {[lecr.LectureTitle]}</h2>
            <h3>{[lecr.When]}</h3>
            {Widget.html lecr.Description}
            
            <hr/>
          </xml>,
          LectureSub.AllFilesAllUsers.ui {LectureNum = lecr.LectureNum},
          Ui.const <xml>
            <hr/>
            <h2>Forum</h2>
          </xml>,
                  LectureForum.ui {LectureNum = lecr.LectureNum})),

         (Ui.when (st >= make [#PollingAboutOfficeHours] ()) "Pset Files",
          PsetSpec.AllFilesAllKeys.ui),

         (Some "Global Forum",
          GlobalForum.ui),
         (Ui.when (st >= make [#PollingAboutOfficeHours] ()) "Grades",
          Ui.seq (Ui.h4 <xml>The range shows your possible final averages, based on grades earned on the remaining assignments.</xml>,
                  StudentGrades.ui u,
                  Ui.const <xml>
                    <hr/>
                    <h3>Feedback</h3>
                  </xml>,
                  PsetGrade.Several.ui (WHERE T.PsetStudent = {[u]}))),
         (Ui.when (st >= make [#PollingAboutOfficeHours] ()) "Old Psets",
          Ui.const <xml>
            <table class="bs3-table table-striped">
              {oldPsets}
            </table>
          </xml>),
         (Some "Course Info",
          courseInfo))

    structure PsetCal = Calendar.FromTable(struct
                                               con tag = #Pset
                                               con key = [PsetNum = _]
                                               con times = [Released, Due, GradesDue]
                                               val tab = pset
                                               val title = "Pset"
                                               val labels = {PsetNum = "Pset#",
                                                             Instructions = "Instructions",
                                                             Released = "Released",
                                                             Due = "Due",
                                                             GradesDue = "Grades due"}
                                               val kinds = {Released = "released", Due = "due", GradesDue = "grades due"}
                                               val ws = {Instructions = Widget.htmlbox} ++ _
                                               val display = Some (fn ctx r =>
                                                                      content <- source <xml/>;
                                                                      lb <- rpc (getPset r.PsetNum);
                                                                      set content (Ui.simpleModal
                                                                                       <xml>
                                                                                         <h2>Pset #{[r.PsetNum]}</h2>
                                                                                         <h3>Released {[lb.Released]}<br/>
                                                                                         Due {[lb.Due]}</h3>
                                                                                         
                                                                                         {Widget.html lb.Instructions}
                                                                                       </xml>
                                                                                       <xml>Close</xml>);
                                                                      return <xml>
                                                                        <dyn signal={signal content}/>
                                                                      </xml>)

                                               val auth = instructorOnly
                                               val showTime = True
                                           end)

    structure AdminCal = Calendar.Make(struct
                                           val t = ThisTerm.cal
                                                       |> Calendar.compose OhCal.cal
                                                       |> Calendar.compose PsetCal.cal
                                                       |> Calendar.compose LectureCal.cal
                                       end)

    structure WS = WebSIS.Make(struct
                                   val user = user

                                   val defaults = {Password = None,
                                                   IsInstructor = False,
                                                   IsTA = False}
                                   val amAuthorized = amInstructor
                                   val expectedSubjectNumber = "6.887"
                               end)

    fun psetGrades n u =
        requireStaff;
        Theme.simple ("Grading Pset #" ^ show n ^ ", " ^ u)
                     (Ui.seq
                          (PsetSub.AllFiles.ui {Key = {PsetNum = n}, User = u},
                           PsetGrade.One.ui {PsetNum = n, PsetStudent = u}))

    structure Students = SimpleQuery1.Make(struct
                                               val query = (SELECT user.Kerberos, user.UserName
                                                            FROM user
                                                            WHERE user.IsStudent
                                                            ORDER BY user.UserName)

                                               val labels = {Kerberos = "Kerberos",
                                                             UserName = "Name"}
                                           end)

    structure GradingTodo = Todo.Grading(struct
                                             con tag = #Grading
                                             con akey = [PsetNum = _]
                                             con due = #GradesDue
                                             con ukey = #UserName
                                             con guser = #PsetStudent

                                             val assignments = pset
                                             val acond = (WHERE Assignments.Due < CURRENT_TIMESTAMP)
                                             val users = user
                                             val ucond = (WHERE Users.IsStudent)
                                             val grades = psetGrade
                                             val gcond = (WHERE Graders.IsTA)

                                             val title = "Grading"
                                             fun render r u =
                                                 <xml><a link={psetGrades r.PsetNum r.PsetStudent}>Grade Pset {[r.PsetNum]} for {[r.PsetStudent]}</a></xml>
                                         end)

    structure LectureUploadTodo = Todo.WithDueDate(struct
                                                       con tag = #Lecture
                                                       con due = #When
                                                       con key = [LectureNum = _]
                                                       val items = lecture
                                                       val done = LectureSub.submission
                                                       con ukey = #UserName
                                                       val users = user
                                                       val title = "Lecture"
                                                       val ucond = (WHERE Users.IsInstructor)
                                                       val allowAnyUser = True

                                                       fun render r _ = <xml>{[r]}</xml>
                                                   end)

    structure PsetUploadTodo = Todo.WithDueDate(struct
                                                    con tag = #Pset
                                                    con due = #Released
                                                    con key = [PsetNum = _]
                                                    val items = pset
                                                    val done = PsetSpec.submission
                                                    con ukey = #UserName
                                                    val users = user
                                                    val title = "Pset"
                                                    val ucond = (WHERE Users.IsInstructor)
                                                    val allowAnyUser = True

                                                    fun render r _ = <xml>{[r]}</xml>
                                                end)

    structure ContentTodo = Todo.Make(struct
                                          val t = LectureUploadTodo.todo
                                                      |> Todo.compose PsetUploadTodo.todo
                                    end)

    structure StaffTodo = Todo.Make(struct
                                        val t = LectureTodo.todo
                                                    |> Todo.compose GradingTodo.todo
                                    end)

    structure Grades = MitGrades.Make(struct
                                          con groups = [IsInstructor, IsTA, HasDropped]
                                          con others = [Kerberos = _, Password = _]
                                          constraint [MitId, UserName, IsStudent, IsListener, Units, SubjectNum, SectionNum, LastName, FirstName, MiddleInitial, Grade, Min, Max] ~ (mapU bool groups ++ others)
                                          val users = user
                                          val grades = gradeTree
                                          val access =
                                              staff <- amStaff;
                                              return (if staff then
                                                          FinalGrades.Write
                                                      else
                                                          FinalGrades.Forbidden)
                                      end)

    structure TimeSpent = SimpleQuery.Make(struct
                                               val submission = PsetSub.submission

                                               val query = (SELECT AVG(submission.Hours) AS Avg, MAX(submission.Hours) AS Max, MIN(submission.Hours) AS Min, COUNT( * ) AS Count, submission.PsetNum AS PsetNum
                                                            FROM (SELECT submission.PsetNum AS PsetNum, MAX(submission.Hours) AS Hours
                                                                  FROM submission
                                                                  WHERE submission.Hours > 0
                                                                  GROUP BY submission.PsetNum, submission.UserName) AS Submission
                                                              JOIN pset ON submission.PsetNum = pset.PsetNum
                                                            WHERE pset.Due < CURRENT_TIMESTAMP
                                                            GROUP BY submission.PsetNum
                                                            ORDER BY submission.PsetNum)

                                               val labels = {Avg = "Average",
                                                             Max = "Maximum",
                                                             Min = "Minimum",
                                                             Count = "Count",
                                                             PsetNum = "Pset#"}
                                           end)

    structure Suggestions = SimpleQuery1.Make(struct
                                                  val submission = PsetSub.submission
                                                                   
                                                  val query = (SELECT submission.Suggestions, submission.PsetNum
                                                               FROM submission
                                                                 JOIN pset ON submission.PsetNum = pset.PsetNum
                                                               WHERE pset.Due < CURRENT_TIMESTAMP
                                                                 AND submission.Suggestions <> ''
                                                               ORDER BY submission.PsetNum, submission.Suggestions)

                                                  val labels = {Suggestions = "Suggestions",
                                                                PsetNum = "Pset#"}
                                              end)

    fun oldPsetStaff id =
        u <- whoamiStaff;
        ps <- oneRow1 (SELECT pset.Released, pset.Due, pset.Instructions
                       FROM pset
                       WHERE pset.PsetNum = {[id]});
        Theme.simple ("MIT 6.887 Staff: Pset " ^ show id)
        (Ui.seq
             (Ui.constM (fn ctx => <xml>
               <h2>Pset {[id]}</h2>
               <h3>Released: {[ps.Released]}<br/>
                 Due: {[ps.Due]}</h3>
                 {Widget.html ps.Instructions}

                 {Ui.modalButton ctx (CLASS "btn btn-primary") <xml>Upload File</xml>
                                 (PsetSpec.newUpload {PsetNum = id})}
                 
                 <hr/>
             </xml>),
              PsetSpec.AllFilesAllUsers.ui {PsetNum = id}))

    fun staff masqAs =
        (case masqAs of
             "" => Auth.unmasquerade
           | _ => Auth.masqueradeAs masqAs);

        u <- getStaff;
        key <- return {UserName = u};
        st <- Sm.current;

        lec <- oneOrNoRows1 (SELECT lecture.LectureNum, lecture.LectureTitle, lecture.When, lecture.Description
                             FROM lecture
                             WHERE lecture.When < CURRENT_TIMESTAMP
                             ORDER BY lecture.When DESC
                             LIMIT 1);

        lecr <- return (Option.get {LectureNum = 0,
                                    LectureTitle = "",
                                    When = minTime,
                                    Description = ""} lec);

        nlec <- oneOrNoRows1 (SELECT lecture.LectureNum, lecture.LectureTitle, lecture.When, lecture.Description
                              FROM lecture
                              WHERE lecture.When > CURRENT_TIMESTAMP
                              ORDER BY lecture.When
                              LIMIT 1);

        nlecr <- return (Option.get {LectureNum = 0,
                                     LectureTitle = "",
                                     When = minTime,
                                     Description = ""} nlec);

        ps <- oneOrNoRows1 (SELECT pset.PsetNum, pset.Released, pset.Due, pset.Instructions
                            FROM pset
                            WHERE pset.Released < CURRENT_TIMESTAMP AND CURRENT_TIMESTAMP < pset.Due
                            ORDER BY pset.Due DESC
                            LIMIT 1);

        psr <- return (Option.get {PsetNum = 0,
                                   Released = minTime,
                                   Due = minTime,
                                   Instructions = ""} ps);

        lps <- oneOrNoRows1 (SELECT pset.PsetNum, pset.Released, pset.Due, pset.Instructions
                             FROM pset
                             WHERE pset.Due <= CURRENT_TIMESTAMP
                             ORDER BY pset.Due DESC
                             LIMIT 1);

        lpsr <- return (Option.get {PsetNum = 0,
                                    Released = minTime,
                                    Due = minTime,
                                    Instructions = ""} lps);

        nps <- oneOrNoRows1 (SELECT pset.PsetNum, pset.Released, pset.Due, pset.Instructions
                             FROM pset
                             WHERE pset.Released > CURRENT_TIMESTAMP
                             ORDER BY pset.Due
                             LIMIT 1);

        npsr <- return (Option.get {PsetNum = 0,
                                    Released = minTime,
                                    Due = minTime,
                                    Instructions = ""} nps);

        oldPsets <- queryX1 (SELECT pset.PsetNum
                             FROM pset
                             WHERE pset.Due < CURRENT_TIMESTAMP
                             ORDER BY pset.Due)
                            (fn r => <xml><tr><td><a link={oldPsetStaff r.PsetNum}>{[r]}</a></td></tr></xml>);

        Theme.tabbed "MIT 6.887, Spring 2017 Staff"
                     ((Ui.when (st = make [#PollingAboutOfficeHours] ()) "Poll on Favorite Office-Hours Times",
                       OhPoll.ui {Ballot = (), Voter = key}),
                      (Ui.when (st >= make [#AssigningFinalGrades] ()) "Final Grades",
                       Grades.ui),
                      (Some "Todo",
                       Ui.seq (ContentTodo.OneUser.ui u,
                               StaffTodo.OneUser.ui u)),
                      (Some "Calendar",
                       AdminCal.ui calBounds),
                      (Some "News",
                       Ann.ui),
                      (Some "Hints",
                       EditHint.ui),

                      (case nlec of
                           None => None
                         | Some _ => Some "Next Lecture",
                       Ui.seq (Ui.constM (fn ctx => <xml>
                         <h2>Lecture {[nlecr.LectureNum]}: {[nlecr.LectureTitle]}</h2>
                         <h3>{[nlecr.When]}</h3>
                         {Widget.html nlecr.Description}

                         {Ui.modalButton ctx (CLASS "btn btn-primary") <xml>Upload Code</xml>
                                         (LectureSub.newUpload {LectureNum = nlecr.LectureNum})}

                         <hr/>
                       </xml>),
                               LectureSub.AllFilesAllUsers.ui {LectureNum = nlecr.LectureNum})),

                      (case nps of
                           None => None
                         | Some _ => Some "Next Pset",
                       Ui.seq (Ui.constM (fn ctx => <xml>
                         <h2>Pset {[npsr.PsetNum]}</h2>
                         <h3>Released: {[npsr.Released]}<br/>
                         Due: {[npsr.Due]}</h3>
                         {Widget.html npsr.Instructions}

                         {Ui.modalButton ctx (CLASS "btn btn-primary") <xml>Upload File</xml>
                                         (PsetSpec.newUpload {PsetNum = npsr.PsetNum})}

                         <hr/>
                       </xml>),
                               PsetSpec.AllFilesAllUsers.ui {PsetNum = npsr.PsetNum})),

                      (case ps of   
                           None => None
                         | Some _ => Some "Current Pset",
                       Ui.seq (Ui.constM (fn ctx => <xml>
                         <h2>Pset {[psr.PsetNum]}</h2>
                         <h3>Released: {[psr.Released]}<br/>
                         Due: {[psr.Due]}</h3>
                         {Widget.html psr.Instructions}

                         {Ui.modalButton ctx (CLASS "btn btn-primary") <xml>Upload File</xml>
                                         (PsetSpec.newUpload {PsetNum = psr.PsetNum})}

                         <hr/>

                         <h2>Forum</h2>
                       </xml>),
                       PsetForum.ui {PsetNum = psr.PsetNum})),

                      (case lps of
                           None => None
                         | Some _ => Some "Last Pset",
                       Ui.seq (Ui.constM (fn ctx => <xml>
                         <h2>Pset {[lpsr.PsetNum]}</h2>
                         <h3>Released: {[lpsr.Released]}<br/>
                         Due: {[lpsr.Due]}</h3>
                         {Widget.html lpsr.Instructions}

                         {Ui.modalButton ctx (CLASS "btn btn-primary") <xml>Upload File</xml>
                                         (PsetSpec.newUpload {PsetNum = lpsr.PsetNum})}

                         <hr/>
                       </xml>),
                               PsetSpec.AllFilesAllUsers.ui {PsetNum = lpsr.PsetNum})),

                      (case lec of
                           None => None
                         | Some _ => Some "Last Lecture",
                       Ui.seq (Ui.const <xml>
                         <h2>Lecture {[lecr.LectureNum]}: {[lecr.LectureTitle]}</h2>
                         <h3>{[lecr.When]}</h3>
                         {Widget.html lecr.Description}

                         <hr/>

                         <h2>Forum</h2>
                       </xml>,
                               LectureForum.ui {LectureNum = lecr.LectureNum})),

                      (Ui.when (st >= make [#PollingAboutOfficeHours] ()) "Global Forum",
                       GlobalForum.ui),
                      (Ui.when (st >= make [#PollingAboutOfficeHours] ()) "Old Psets",
                       Ui.const <xml>
                         <table class="bs3-table table-striped">
                           {oldPsets}
                         </table>
                       </xml>),
                      (Some "Students",
                       Students.ui),
                      (Ui.when (st >= make [#PollingAboutOfficeHours] ()) "Pset Time Stats",
                       TimeSpent.ui),
                      (Ui.when (st >= make [#PollingAboutOfficeHours] ()) "Pset Suggestions",
                       Suggestions.ui),
                      (Ui.when (st > make [#PollingAboutOfficeHours] ()) "Grades",
                       AllGrades.ui),
                      (Ui.when (st = make [#SteadyState] ()) "Poll on Favorite Office-Hours Times",
                       OhPoll.ui {Ballot = (), Voter = key}))

    val admin =
        requireInstructor;
        tm <- now;
        st <- Sm.current;

        masq <- queryX1 (SELECT user.UserName
                         FROM user
                         WHERE user.IsStudent
                         ORDER BY user.UserName)
                        (fn r => <xml>
                          <tr><td><a link={student r.UserName}>{[r.UserName]}</a></td></tr>
                        </xml>);

        smasq <- queryX1 (SELECT user.UserName
                          FROM user
                          WHERE user.IsTA
                          ORDER BY user.UserName)
                         (fn r => <xml>
                           <tr><td><a link={staff r.UserName}>{[r.UserName]}</a></td></tr>
                         </xml>);

        Theme.tabbed "MIT 6.887, Spring 2017 Admin"
                     ((Some "Lifecycle",
                       Smu.ui),
                      (Some "Calendar",
                       AdminCal.ui calBounds),
                      (Some "Import",
                       WS.ui),
                      (Some "Users",
                       EditUser.ui),
                      (Ui.when (st < make [#SteadyState] ()) "Possible OH times",
                       Ui.seq (Ui.h4 <xml>Enter times like "{[tm]}".  Only the time part will be shown to students.</xml>,
                               EditPossOh.ui)),
                      (Some "Student Masquerade",
                       Ui.const <xml>
                         <table class="bs3-table table-striped">
                           {masq}
                         </table>
                       </xml>),
                      (Some "TA Masquerade",
                       Ui.const <xml>
                         <table class="bs3-table table-striped">
                           {smasq}
                         </table>
                       </xml>))

end

val main =
    st <- Sm.current;

    Theme.tabbed "MIT 6.887, Spring 2017"
                 ((Some "Course Info",
                   Ui.seq (Ui.const (if st < make [#PollingAboutOfficeHours] () then
                                         <xml></xml>
                                     else
                                         <xml><p>
                                           <a class="btn btn-primary btn-lg" link={Private.student ""}>Go to student portal</a>
                                           (requires an <a href="https://ist.mit.edu/certificates">MIT client certificate</a>)
                                         </p></xml>),
                           courseInfo)),
                  (Ui.when (st >= make [#ReleaseCalendar] ()) "Calendar",
                   calUi))

val login =
    Theme.simple "MIT 6.887, non-MIT user login" Auth.Login.ui

val index = return <xml><body>
  <a link={main}>Main</a>
  <a link={Private.admin}>Admin</a>
  <a link={Private.staff ""}>Staff</a>
  <a link={Private.student ""}>Student</a>
  <a link={Private.psetGrades 0 ""}>Grade</a>
  <a link={login}>Login</a>
</body></xml>
