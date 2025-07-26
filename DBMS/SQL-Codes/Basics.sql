CREATE DATABASE IF NOT EXISTS instagramDb;

USE instagramDb;

CREATE TABLE IF NOT EXISTS users(
userId INT PRIMARY KEY,
userName VARCHAR(50),
email  VARCHAR(100)
);

CREATE TABLE IF NOT EXISTS posts(
postId INT PRIMARY KEY,
userId INT,
caption VARCHAR(100)
);

INSERT INTO users VALUES 
(1,"Ankur Verma", "ankur@gmail.com"),
(2,"Isha Kumari","isha@gmail.com"),
(3,"Deepak Yadav","deepak@gmail.com");

INSERT INTO posts VALUES 
(101,561,"light"),
(102,562,"water"),
(103,563,"air");

SHOW TABLES;

SELECT  * FROM users;

SELECT * FROM posts;