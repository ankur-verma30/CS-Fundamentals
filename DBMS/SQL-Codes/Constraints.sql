CREATE DATABASE college;

USE  college;

-- unique contraint
CREATE TABLE student(
phonenbr INT UNIQUE
);

INSERT INTO student VALUES
(123),
(456);

-- not null constraint 
CREATE TABLE  student1(
age INT,
rollno INT NOT NULL
);

INSERT INTO student1 VALUES
(23,123);

-- check contraint
CREATE TABLE student2(
age INT  CHECK(age>18)
);

INSERT INTO student2 VALUES 
(19);

-- default constraint
CREATE TABLE student3  (
schoolName VARCHAR(50) DEFAULT 'RLB',
age INT
);

INSERT INTO student3 (age) VALUES (23);

 SELECT * FROM student3;
 
 -- primary key constraint
 
 CREATE TABLE student4(
 age INT,
 rollNo INT PRIMARY KEY
 );
 
 -- unique
 INSERT INTO student4 VALUES 
 (12,1),
 (13,2),
 (14,3);
 
 -- not null 
 
 INSERT INTO student4 (age,rollNo) VALUES
 (12,5),
 (13,6);
 
 SELECT * FROM student4;
 
 -- foreign key
 CREATE TABLE course(
 courseName  VARCHAR(50),
 rollNo INT,
 FOREIGN KEY (rollNo) REFERENCES student4(rollNo)
 );
 
 SELECT * FROM course;