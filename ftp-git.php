<?php

ftpgit_readdir('./');
	
function ftpgit_readdir($dirname) {
	echo $dirname." ## DIR\n";
	$handle = opendir($dirname);
	$files = array();
	while (false !== ($file = readdir($handle))) {
		if ($file != '.' && $file != '..' && $dirname.$file != './ftp-git.php') {
			$files[] = $dirname.$file;
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