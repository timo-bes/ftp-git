<?php

ftpgit_readdir('./');
	
function ftpgit_readdir($dirname) {
	echo $dirname." ## DIR\n";
	$handle = opendir($dirname);
	$files = array();
	while (false !== ($file = readdir($handle))) {
		$fullName = $dirname.$file;
		if ($file != '.' && $file != '..' && $fullName != './ftp-git.php'
				&& $file != '.git-ftp.log' && $file != '.ftp-git.log') {
			$files[] = $fullName;
		}
	}
	asort($files);
	foreach ($files as $file) {
		if (is_file($file)) {
			echo $file.' ## '.filemtime($file)."\n";
		} else {
			ftpgit_readdir($file.'/');
		}
	}
	closedir($handle);
}

?>